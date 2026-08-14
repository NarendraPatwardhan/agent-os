use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::Path;

fn pad4(out: &mut Vec<u8>) {
    while out.len() % 4 != 0 {
        out.push(0);
    }
}

fn append(out: &mut Vec<u8>, name: &str, mode: u32, data: &[u8], ino: u32, rdev: u64) {
    let name_size = name.len() + 1;
    let header = format!(
        "070701{ino:08x}{mode:08x}{uid:08x}{gid:08x}{nlink:08x}{mtime:08x}{size:08x}{major:08x}{minor:08x}{rmajor:08x}{rminor:08x}{name_size:08x}{check:08x}",
        uid = 0,
        gid = 0,
        nlink = 1,
        mtime = 0,
        size = data.len(),
        major = 0,
        minor = 0,
        rmajor = libc_major(rdev),
        rminor = libc_minor(rdev),
        check = 0,
    );
    assert_eq!(header.len(), 110);
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(name.as_bytes());
    out.push(0);
    pad4(out);
    out.extend_from_slice(data);
    pad4(out);
}

fn archive(init: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(init.len() + 512);
    append(&mut out, "init", 0o100755, init, 1, 0);
    append(&mut out, "TRAILER!!!", 0, &[], 2, 0);
    out
}

fn archive_root(root: &Path) -> io::Result<Vec<u8>> {
    let mut paths = Vec::new();
    collect(root, root, &mut paths)?;
    paths.sort();

    let mut out = Vec::new();
    for (index, relative) in paths.iter().enumerate() {
        let path = root.join(relative);
        let metadata = fs::symlink_metadata(&path)?;
        let file_type = metadata.file_type();
        let data = if file_type.is_file() {
            fs::read(&path)?
        } else if file_type.is_symlink() {
            fs::read_link(&path)?
                .as_os_str()
                .as_encoded_bytes()
                .to_vec()
        } else {
            Vec::new()
        };
        // The OCI base contains general-purpose setuid/setgid utilities that this appliance never
        // needs. Every archived path is root-owned, so retaining either bit would turn ordinary base
        // image tools into privilege-escalation paths for the unprivileged browser processes.
        let mut mode = strip_privilege_bits(metadata.mode());
        if file_type.is_dir() {
            mode = (mode & 0o7777) | 0o040000;
        } else if file_type.is_symlink() {
            mode = (mode & 0o7777) | 0o120000;
        } else if file_type.is_char_device() {
            mode = (mode & 0o7777) | 0o020000;
        } else if file_type.is_block_device() {
            mode = (mode & 0o7777) | 0o060000;
        } else if file_type.is_fifo() {
            mode = (mode & 0o7777) | 0o010000;
        } else if file_type.is_socket() {
            continue;
        }
        append(
            &mut out,
            relative.to_str().ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "rootfs path is not UTF-8")
            })?,
            mode,
            &data,
            (index + 1) as u32,
            metadata.rdev(),
        );
    }
    append(&mut out, "TRAILER!!!", 0, &[], (paths.len() + 1) as u32, 0);
    Ok(out)
}

fn strip_privilege_bits(mode: u32) -> u32 {
    mode & !0o6000
}

fn collect(root: &Path, directory: &Path, paths: &mut Vec<std::path::PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        let relative = path
            .strip_prefix(root)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "rootfs traversal"))?
            .to_owned();
        paths.push(relative);
        if entry.file_type()?.is_dir() {
            collect(root, &path, paths)?;
        }
    }
    Ok(())
}

fn libc_major(device: u64) -> u64 {
    ((device >> 8) & 0xfff) | ((device >> 32) & 0xfffff000)
}

fn libc_minor(device: u64) -> u64 {
    (device & 0xff) | ((device >> 12) & 0xffffff00)
}

fn main() -> io::Result<()> {
    let mut args = env::args_os().skip(1);
    let first = args
        .next()
        .expect("usage: mkinitramfs INIT OUTPUT | --root ROOT OUTPUT");
    let second = args
        .next()
        .expect("usage: mkinitramfs INIT OUTPUT | --root ROOT OUTPUT");
    let (bytes, output) = if first == "--root" {
        let output = args.next().expect("usage: mkinitramfs --root ROOT OUTPUT");
        (archive_root(Path::new(&second))?, output)
    } else {
        (archive(&fs::read(first)?), second)
    };
    assert!(
        args.next().is_none(),
        "usage: mkinitramfs INIT OUTPUT | --root ROOT OUTPUT"
    );
    let mut file = fs::File::create(Path::new(&output))?;
    file.write_all(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_newc_contains_executable_init_and_trailer() {
        let first = archive(b"guest");
        let second = archive(b"guest");
        assert_eq!(first, second);
        assert!(first.windows(5).any(|part| part == b"guest"));
        assert!(first.windows(10).any(|part| part == b"TRAILER!!!"));
        assert_eq!(&first[..6], b"070701");
        assert_eq!(first.len() % 4, 0);
    }

    #[test]
    fn rootfs_entries_never_retain_setuid_or_setgid() {
        assert_eq!(strip_privilege_bits(0o106755), 0o100755);
        assert_eq!(strip_privilege_bits(0o102755), 0o100755);
    }
}
