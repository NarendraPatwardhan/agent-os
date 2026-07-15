use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::Path;

fn pad4(out: &mut Vec<u8>) {
    while out.len() % 4 != 0 {
        out.push(0);
    }
}

fn append(out: &mut Vec<u8>, name: &str, mode: u32, data: &[u8], ino: u32) {
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
        rmajor = 0,
        rminor = 0,
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
    append(&mut out, "init", 0o100755, init, 1);
    append(&mut out, "TRAILER!!!", 0, &[], 2);
    out
}

fn main() -> io::Result<()> {
    let mut args = env::args_os().skip(1);
    let init = args.next().expect("usage: mkinitramfs INIT OUTPUT");
    let output = args.next().expect("usage: mkinitramfs INIT OUTPUT");
    assert!(args.next().is_none(), "usage: mkinitramfs INIT OUTPUT");
    let bytes = archive(&fs::read(init)?);
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
}
