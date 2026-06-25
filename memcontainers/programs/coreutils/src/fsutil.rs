//! Filesystem helpers shared by the file-management coreutils (`cp`, `mv`, `rm`, `mkdir`,
//! `ls`) and the directory walks (`grep -r`, `find`, `tree`), built on the `//sysroot`
//! primitives. These implement the POSIX userspace conventions the kernel deliberately does
//! not: move/copy INTO a directory, recursive copy/remove, `mkdir -p`, and path
//! canonicalization. They use `alloc` (dynamic paths + recursion).
//!
//! Ported from memcontainers' `programs::fsutil` onto agent-os's `//sysroot`.

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use sysroot as rt;

/// True if `path` exists and is a directory.
pub fn is_dir(path: &str) -> bool {
    rt::stat(path).map(|s| s.is_dir).unwrap_or(false)
}

/// True if `path` exists (file or directory).
pub fn exists(path: &str) -> bool {
    rt::stat(path).is_ok()
}

/// The final path component (`/a/b/` → `b`, `a` → `a`).
pub fn basename(path: &str) -> &str {
    let t = path.trim_end_matches('/');
    match t.rfind('/') {
        Some(i) => &t[i + 1..],
        None => t,
    }
}

/// Join a directory and a name with a single `/`.
pub fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

/// Resolve a copy/move destination: if `dst` is an existing directory, the result is
/// `dst/basename(src)` (the POSIX "into a directory" convention); otherwise `dst` verbatim.
pub fn dest_into_dir(src: &str, dst: &str) -> String {
    if is_dir(dst) {
        join(dst, basename(src))
    } else {
        String::from(dst)
    }
}

/// Lexically normalize a path to an absolute form (collapse `.`/`..`) WITHOUT following
/// symlinks. Used for self-copy checks and as the lexical base of [`canonicalize`].
pub fn lexical_abs(path: &str) -> String {
    let mut joined = String::new();
    if path.starts_with('/') {
        joined.push_str(path);
    } else {
        let mut cwd_buf = [0u8; 1024];
        let n = rt::getcwd(&mut cwd_buf).unwrap_or(0);
        let cwd = core::str::from_utf8(&cwd_buf[..n]).unwrap_or("/");
        joined.push_str(cwd);
        if !cwd.ends_with('/') {
            joined.push('/');
        }
        joined.push_str(path);
    }

    let mut comps: Vec<&str> = Vec::new();
    for comp in joined.split('/').filter(|c| !c.is_empty()) {
        match comp {
            "." => {}
            ".." => {
                comps.pop();
            }
            _ => comps.push(comp),
        }
    }

    let mut out = String::from("/");
    for (i, comp) in comps.iter().enumerate() {
        if i > 0 {
            out.push('/');
        }
        out.push_str(comp);
    }
    out
}

/// Existence requirement for [`canonicalize`] (the `readlink -e`/`-f`/`-m` modes).
#[derive(Clone, Copy)]
pub enum Existence {
    /// Every path component must exist (`readlink -e`).
    All,
    /// Every component but the last must exist (`readlink -f`).
    Parent,
    /// No component need exist (`readlink -m`).
    None,
}

/// Build `/<out…>/<comp>` from a resolved component stack and one more name.
fn abs_path(out: &[String], comp: &str) -> String {
    let mut s = String::from("/");
    for c in out {
        s.push_str(c);
        s.push('/');
    }
    s.push_str(comp);
    s
}

/// Resolve `path` to a canonical absolute path, following symlinks and collapsing `.`/`..`
/// (the kernel does the same internally for `open`/`stat`; this mirrors it in user space so
/// `readlink -f` and `realpath` can return the resolved *path*, which no syscall hands back).
/// Returns `None` on a required missing component (per `existence`) or a symlink loop.
pub fn canonicalize(path: &str, existence: Existence) -> Option<String> {
    let abs = lexical_abs(path);
    let mut out: Vec<String> = Vec::new();
    // Work list: a symlink splices its target in front of the remaining components, so this is
    // not a simple iterator.
    let mut pending: Vec<String> = abs
        .split('/')
        .filter(|c| !c.is_empty())
        .map(String::from)
        .collect();
    let mut hops = 0usize;
    let mut idx = 0usize;
    while idx < pending.len() {
        let comp = pending[idx].clone();
        idx += 1;
        if comp == "." {
            continue;
        }
        if comp == ".." {
            out.pop();
            continue;
        }
        let candidate = abs_path(&out, &comp);
        let is_final = idx == pending.len();
        match rt::lstat(&candidate) {
            Ok(s) if s.is_symlink => {
                hops += 1;
                if hops > 40 {
                    return None;
                }
                let mut buf = [0u8; 1024];
                let nn = rt::readlink(&candidate, &mut buf).ok()?;
                let tgt = core::str::from_utf8(&buf[..nn.min(buf.len())]).ok()?;
                let mut next: Vec<String> = tgt
                    .split('/')
                    .filter(|c| !c.is_empty())
                    .map(String::from)
                    .collect();
                next.extend_from_slice(&pending[idx..]);
                if tgt.starts_with('/') {
                    out.clear();
                }
                pending = next;
                idx = 0;
            }
            Ok(_) => out.push(comp),
            Err(_) => {
                let required = match existence {
                    Existence::All => true,
                    Existence::Parent => !is_final,
                    Existence::None => false,
                };
                if required {
                    return None;
                }
                out.push(comp);
            }
        }
    }
    let mut s = String::from("/");
    for (i, c) in out.iter().enumerate() {
        if i > 0 {
            s.push('/');
        }
        s.push_str(c);
    }
    Some(s)
}

/// True if `candidate` is the same path as `ancestor`, or below it.
pub fn same_or_descendant(ancestor: &str, candidate: &str) -> bool {
    let ancestor = lexical_abs(ancestor);
    let candidate = lexical_abs(candidate);
    if ancestor == "/" {
        return candidate.starts_with('/');
    }
    candidate == ancestor
        || match candidate.strip_prefix(ancestor.as_str()) {
            Some(rest) => rest.starts_with('/'),
            None => false,
        }
}

/// List a directory's entry names (no `.`/`..`).
pub fn list(path: &str) -> Result<Vec<String>, i32> {
    let mut cap = 1024usize;
    loop {
        let mut buf = alloc::vec![0u8; cap];
        match rt::readdir(path, &mut buf) {
            Ok(n) => {
                if n == cap {
                    cap *= 2; // possibly truncated — grow and retry
                    continue;
                }
                return Ok(buf[..n]
                    .split(|&b| b == 0)
                    .filter(|s| !s.is_empty())
                    .map(|s| String::from_utf8_lossy(s).into_owned())
                    .collect());
            }
            Err(e) => return Err(e),
        }
    }
}

/// Copy a single regular file's contents `src` → `dst` (truncating `dst`).
pub fn copy_file(src: &str, dst: &str) -> Result<(), i32> {
    let sfd = rt::open(src, rt::O_READ)?;
    let dfd = match rt::open(dst, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC) {
        Ok(f) => f,
        Err(e) => {
            rt::close(sfd);
            return Err(e);
        }
    };
    let mut buf = [0u8; 4096];
    let result = loop {
        match rt::read(sfd, &mut buf) {
            Ok(0) => break Ok(()),
            Ok(n) => {
                if let Err(e) = rt::write_all(dfd, &buf[..n]) {
                    break Err(e);
                }
            }
            Err(e) => break Err(e),
        }
    };
    rt::close(sfd);
    rt::close(dfd);
    result
}

/// Copy `src`'s permission bits onto `dst` (always — POSIX `cp` copies the mode even without
/// `-p`), and its mtime/atime too when `with_times` (i.e. `cp -p` / `mv`'s cross-mount
/// fallback). Recurses through a directory tree. Symlinks are skipped (there is no
/// `lchmod`/`lutimes`, so chmod/utimes would follow the link and corrupt the target's
/// metadata). Best-effort: a metadata-set failure is ignored so it never fails the copy.
pub fn preserve_meta(src: &str, dst: &str, with_times: bool) {
    let s = match rt::lstat(src) {
        Ok(s) => s,
        Err(_) => return,
    };
    if s.is_symlink {
        return;
    }
    let _ = rt::chmod(dst, s.mode);
    if with_times {
        let _ = rt::utimes(dst, Some((s.atime, s.mtime)));
    }
    if s.is_dir {
        if let Ok(names) = list(src) {
            for name in names {
                preserve_meta(&join(src, &name), &join(dst, &name), with_times);
            }
        }
    }
}

/// Recursively copy `src` → `dst`, dereferencing symlinks (a symlink's target contents are
/// copied). The default `cp -r` behavior.
pub fn copy_recursive(src: &str, dst: &str) -> Result<(), i32> {
    copy_tree(src, dst, true)
}

/// Recursively copy `src` → `dst`. With `follow` false (e.g. `cp -a`), a symlink is recreated
/// as a symlink instead of having its target contents copied; with `follow` true a symlink is
/// dereferenced. A directory is created and its entries copied into it.
pub fn copy_tree(src: &str, dst: &str, follow: bool) -> Result<(), i32> {
    if !follow {
        let ls = rt::lstat(src)?;
        if ls.is_symlink {
            let mut buf = [0u8; 1024];
            let n = rt::readlink(src, &mut buf)?;
            let tgt = core::str::from_utf8(&buf[..n.min(buf.len())]).map_err(|_| rt::EINVAL)?;
            let _ = rt::unlink(dst); // overwrite an existing destination link
            return rt::symlink(tgt, dst);
        }
    }
    if is_dir(src) {
        match rt::mkdir(dst) {
            Ok(()) | Err(rt::EEXIST) => {}
            Err(e) => return Err(e),
        }
        for name in list(src)? {
            copy_tree(&join(src, &name), &join(dst, &name), follow)?;
        }
        Ok(())
    } else {
        copy_file(src, dst)
    }
}

/// Recursively remove `path`. A directory's children are removed first, then the now-empty
/// directory (the kernel `unlink` removes empty directories).
pub fn remove_recursive(path: &str) -> Result<(), i32> {
    if is_dir(path) {
        for name in list(path)? {
            remove_recursive(&join(path, &name))?;
        }
    }
    rt::unlink(path)
}

/// `mkdir -p`: create `path` and any missing ancestors, ignoring components that already
/// exist. Preserves whether `path` is absolute or relative (a relative path is created under
/// the caller's cwd, like the kernel resolves it).
pub fn mkdir_p(path: &str) -> Result<(), i32> {
    let absolute = path.starts_with('/');
    let mut acc = String::new();
    for comp in path.split('/').filter(|c| !c.is_empty()) {
        if acc.is_empty() {
            if absolute {
                acc.push('/');
            }
        } else {
            acc.push('/');
        }
        acc.push_str(comp);
        match rt::mkdir(&acc) {
            Ok(()) | Err(rt::EEXIST) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
