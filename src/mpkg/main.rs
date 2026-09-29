//! Small, strict, first-install-only package manager. No archive extractor runs as root.
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const MAX_ARCHIVE: u64 = 32 * 1024 * 1024;
extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

fn ensure(condition: bool, message: &str) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}
fn token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._+-".contains(&c))
}
fn text(bytes: &[u8]) -> Result<&str> {
    Ok(std::str::from_utf8(bytes)?)
}
fn field(bytes: &[u8]) -> Result<&str> {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    ensure(
        bytes[end..].iter().all(|b| *b == 0),
        "invalid tar string padding",
    )?;
    text(&bytes[..end])
}
fn octal(bytes: &[u8]) -> Result<u64> {
    let value = text(bytes)?.trim_matches(|c| c == '\0' || c == ' ');
    Ok(if value.is_empty() {
        0
    } else {
        u64::from_str_radix(value, 8)?
    })
}
fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 255
        && path.bytes().all(|b| b.is_ascii_graphic())
        && !path.contains('\\')
        && path
            .split('/')
            .all(|p| !p.is_empty() && p != "." && p != "..")
}
fn payload_path(path: &str) -> bool {
    safe_path(path)
        && matches!(
            path.split('/').next(),
            Some("usr" | "opt" | "etc" | "var" | "bin" | "sbin" | "lib")
        )
        && path != "var/lib/mpkg"
        && !path.starts_with("var/lib/mpkg/")
}
#[derive(Clone)]
struct Entry<'a> {
    data: &'a [u8],
    mode: u32,
    directory: bool,
}
struct Package<'a> {
    name: String,
    version: String,
    manifest: &'a [u8],
    files: BTreeMap<String, Entry<'a>>,
}
fn parse_tar(archive: &[u8]) -> Result<Package<'_>> {
    ensure(archive.len() % 512 == 0, "truncated tar archive")?;
    let mut entries = BTreeMap::new();
    let mut offset = 0;
    loop {
        let header = archive
            .get(offset..offset + 512)
            .ok_or("missing tar end marker")?;
        if header.iter().all(|b| *b == 0) {
            ensure(
                archive.len() >= offset + 1024 && archive[offset..].iter().all(|b| *b == 0),
                "invalid tar trailer",
            )?;
            break;
        }
        let sum: u64 = header
            .iter()
            .enumerate()
            .map(|(i, b)| {
                if (148..156).contains(&i) {
                    32
                } else {
                    *b as u64
                }
            })
            .sum();
        ensure(
            sum == octal(&header[148..156])?,
            "invalid tar header checksum",
        )?;
        ensure(
            &header[257..265] == b"ustar\000",
            "only POSIX ustar packages are supported",
        )?;
        ensure(
            octal(&header[108..116])? == 0 && octal(&header[116..124])? == 0,
            "package ownership must be root",
        )?;
        let directory = header[156] == b'5';
        ensure(
            directory || header[156] == b'0' || header[156] == 0,
            "links and special archive entries are unsupported",
        )?;
        ensure(
            field(&header[157..257])?.is_empty(),
            "unexpected tar link target",
        )?;
        let prefix = field(&header[345..500])?;
        let name = field(&header[..100])?;
        let path = if prefix.is_empty() {
            name.to_owned()
        } else {
            format!("{prefix}/{name}")
        };
        let path = if directory {
            path.strip_suffix('/').unwrap_or(&path).to_owned()
        } else {
            path
        };
        ensure(safe_path(&path), "unsafe archive path")?;
        let mode = octal(&header[100..108])?;
        ensure(
            mode & !0o777 == 0,
            "special permission bits are unsupported",
        )?;
        let size = usize::try_from(octal(&header[124..136])?)?;
        ensure(
            size <= MAX_ARCHIVE as usize && (!directory || size == 0),
            "invalid archive entry size",
        )?;
        offset += 512;
        let data = archive
            .get(offset..offset + size)
            .ok_or("truncated archive entry")?;
        offset += size.div_ceil(512) * 512;
        ensure(
            entries
                .insert(
                    path,
                    Entry {
                        data,
                        mode: mode as u32,
                        directory,
                    },
                )
                .is_none(),
            "duplicate archive path",
        )?;
    }
    for (path, entry) in &entries {
        let mut parent = Path::new(path).parent();
        while let Some(p) = parent.filter(|p| !p.as_os_str().is_empty()) {
            if let Some(e) = entries.get(p.to_str().ok_or("invalid path")?) {
                ensure(e.directory, "archive has a non-directory parent")?;
            }
            parent = p.parent();
        }
        ensure(
            path == "manifest" || path == "files" || path == "root" || path.starts_with("root/"),
            "unexpected archive member",
        )?;
        if path == "root" {
            ensure(entry.directory, "root must be a directory")?;
        }
    }
    let manifest = entries.remove("manifest").ok_or("missing manifest")?;
    let declared = entries.remove("files").ok_or("missing file list")?;
    ensure(
        !manifest.directory && !declared.directory,
        "metadata must be regular files",
    )?;
    let mut values = BTreeMap::new();
    for line in text(manifest.data)?.lines() {
        let (key, value) = line.split_once('=').ok_or("invalid manifest")?;
        ensure(
            matches!(key, "name" | "version") && token(value),
            "invalid manifest field",
        )?;
        ensure(
            values.insert(key, value).is_none(),
            "duplicate manifest field",
        )?;
    }
    let name = values.get("name").ok_or("missing name")?.to_string();
    let version = values.get("version").ok_or("missing version")?.to_string();
    let mut files = BTreeMap::new();
    for (path, entry) in entries {
        if path == "root" {
            continue;
        }
        let path = path.strip_prefix("root/").ok_or("invalid payload path")?;
        ensure(payload_path(path), "unsafe or reserved payload path")?;
        if !entry.directory {
            files.insert(path.to_owned(), entry);
        }
    }
    ensure(!files.is_empty(), "empty package")?;
    let mut declared_paths = BTreeSet::new();
    for line in text(declared.data)?.lines() {
        let path = line
            .strip_prefix('/')
            .ok_or("file list paths must be absolute")?;
        ensure(
            payload_path(path) && declared_paths.insert(path.to_owned()),
            "invalid or duplicate file list path",
        )?;
    }
    ensure(
        declared_paths == files.keys().cloned().collect(),
        "file list does not match payload",
    )?;
    Ok(Package {
        name,
        version,
        manifest: manifest.data,
        files,
    })
}
fn sync_dir(path: &Path) -> Result<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}
fn write_file(path: &Path, data: &[u8], mode: u32) -> Result<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(data)?;
    f.set_permissions(fs::Permissions::from_mode(mode))?;
    f.sync_all()?;
    Ok(())
}
// Never follow a payload-parent symlink, including links already in the base OS.
fn directories(root: &Path, relative: &Path, create: bool) -> Result<()> {
    let mut path = root.to_path_buf();
    for part in relative.components() {
        ensure(
            matches!(part, std::path::Component::Normal(_)),
            "unsafe directory path",
        )?;
        path.push(part);
        match fs::symlink_metadata(&path) {
            Ok(meta) => ensure(meta.is_dir(), "payload parent is not a real directory")?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                if create {
                    fs::create_dir(&path)?;
                    fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
                    sync_dir(path.parent().ok_or("missing parent")?)?;
                }
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}
fn recover(root: &Path, db: &Path) -> Result<()> {
    let tx = db.join(".transaction");
    if !tx.exists() {
        return Ok(());
    }
    if tx.join("installing").exists() {
        // Journal was synced before linking any payload. Only unlink our own inodes.
        for line in fs::read_to_string(tx.join("files"))?.lines() {
            let relative = line.strip_prefix('/').ok_or("invalid recovery journal")?;
            ensure(payload_path(relative), "unsafe recovery journal")?;
            directories(
                root,
                Path::new(relative).parent().ok_or("missing parent")?,
                false,
            )?;
            let dest = root.join(relative);
            if let (Ok(a), Ok(b)) = (
                fs::symlink_metadata(&dest),
                fs::symlink_metadata(tx.join("payload").join(relative)),
            ) {
                if a.dev() == b.dev() && a.ino() == b.ino() {
                    fs::remove_file(&dest)?;
                    sync_dir(dest.parent().ok_or("missing parent")?)?;
                }
            }
        }
    }
    fs::remove_dir_all(tx)?;
    sync_dir(db)
}
fn install(root: &Path, package: &Package<'_>) -> Result<()> {
    directories(root, Path::new("var/lib/mpkg"), true)?;
    let db = root.join("var/lib/mpkg");
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(db.join(".lock"))?;
    if unsafe { flock(lock.as_raw_fd(), 2 | 4) } != 0 {
        return Err(format!(
            "cannot lock package database: {}",
            io::Error::last_os_error()
        )
        .into());
    }
    recover(root, &db)?;
    ensure(
        !db.join(&package.name).exists() && !db.join(format!("{}.manifest", package.name)).exists(),
        "package already installed; upgrades are unsupported",
    )?;
    for path in package.files.keys() {
        directories(
            root,
            Path::new(path).parent().ok_or("missing parent")?,
            false,
        )?;
        match fs::symlink_metadata(root.join(path)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
            Ok(_) => return Err(format!("destination already exists: /{path}").into()),
        }
    }
    let tx = db.join(".transaction");
    fs::create_dir(&tx)?;
    let result = (|| -> Result<()> {
        fs::create_dir(tx.join("payload"))?;
        let list = package
            .files
            .keys()
            .map(|p| format!("/{p}\n"))
            .collect::<String>();
        write_file(&tx.join("files"), list.as_bytes(), 0o644)?;
        write_file(&tx.join("manifest"), package.manifest, 0o644)?;
        for (path, entry) in &package.files {
            let staged = tx.join("payload").join(path);
            directories(
                &tx.join("payload"),
                Path::new(path).parent().ok_or("missing parent")?,
                true,
            )?;
            write_file(&staged, entry.data, entry.mode)?;
            sync_dir(staged.parent().ok_or("missing parent")?)?;
        }
        sync_dir(&tx.join("payload"))?;
        write_file(&tx.join("installing"), b"", 0o600)?;
        sync_dir(&tx)?;
        sync_dir(&db)?;
        for path in package.files.keys() {
            let dest = root.join(path);
            directories(
                root,
                Path::new(path).parent().ok_or("missing parent")?,
                true,
            )?;
            // Atomic no-clobber publication; all payload and journal entries are durable.
            fs::hard_link(tx.join("payload").join(path), &dest)?;
            sync_dir(dest.parent().ok_or("missing parent")?)?;
        }
        // One rename is the commit point for the package's ownership and manifest.
        fs::rename(&tx, db.join(&package.name))?;
        sync_dir(&db)?;
        Ok(())
    })();
    if let Err(error) = result {
        recover(root, &db)?;
        return Err(error);
    }
    // Committed payload hard links can be removed; a crash here is harmless.
    let committed = db.join(&package.name);
    let _ = fs::remove_dir_all(committed.join("payload"));
    let _ = fs::remove_file(committed.join("installing"));
    Ok(())
}
fn run() -> Result<()> {
    let args = std::env::args().collect::<Vec<_>>();
    ensure(
        (args.len() == 3 || args.len() == 4) && args[1] == "install",
        "usage: mpkg install PACKAGE [SHA256_FILE]",
    )?;
    let package = PathBuf::from(&args[2]);
    let checksum = args
        .get(3)
        .cloned()
        .unwrap_or_else(|| format!("{}.sha256", args[2]));
    let expected = fs::read_to_string(checksum)?;
    let expected = expected
        .split_whitespace()
        .next()
        .ok_or("empty checksum file")?;
    ensure(
        expected.len() == 64 && expected.bytes().all(|b| b.is_ascii_hexdigit()),
        "invalid SHA-256",
    )?;
    let actual = Command::new("sha256sum").arg("--").arg(&package).output()?;
    ensure(actual.status.success(), "cannot checksum package")?;
    ensure(
        text(&actual.stdout)?
            .split_whitespace()
            .next()
            .map(|s| s.eq_ignore_ascii_case(expected))
            == Some(true),
        "SHA-256 mismatch",
    )?;
    let mut child = Command::new("zstd")
        .args(["-q", "-d", "-c", "--"])
        .arg(package)
        .stdout(Stdio::piped())
        .spawn()?;
    let mut archive = Vec::new();
    let read = child
        .stdout
        .take()
        .ok_or("no decoder output")?
        .take(MAX_ARCHIVE + 1)
        .read_to_end(&mut archive);
    if read.is_err() || archive.len() as u64 > MAX_ARCHIVE {
        let _ = child.kill();
        let _ = child.wait();
        return Err("cannot decode package within 32 MiB limit".into());
    }
    ensure(child.wait()?.success(), "zstd decompression failed")?;
    let package = parse_tar(&archive)?;
    install(Path::new("/"), &package)?;
    println!("mpkg: installed {} {}", package.name, package.version);
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("mpkg: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static SEQUENCE: AtomicUsize = AtomicUsize::new(0);
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "mpkg-test-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn archive(members: &[(&str, u8, &[u8])]) -> Vec<u8> {
        let mut out = Vec::new();
        for (path, kind, data) in members {
            let mut h = [0u8; 512];
            h[..path.len()].copy_from_slice(path.as_bytes());
            h[100..108].copy_from_slice(b"0000644\0");
            h[108..116].copy_from_slice(b"0000000\0");
            h[116..124].copy_from_slice(b"0000000\0");
            h[124..136].copy_from_slice(format!("{:011o}\0", data.len()).as_bytes());
            h[148..156].fill(b' ');
            h[156] = *kind;
            h[257..265].copy_from_slice(b"ustar\x0000");
            let sum: u32 = h.iter().map(|b| *b as u32).sum();
            h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
            out.extend(h);
            out.extend(*data);
            out.resize(out.len().div_ceil(512) * 512, 0);
        }
        out.extend([0; 1024]);
        out
    }
    fn fixture(files: &[u8], path: &str, kind: u8) -> Vec<u8> {
        archive(&[
            ("manifest", b'0', b"name=demo\nversion=1\n"),
            ("files", b'0', files),
            (path, kind, b"hello\n"),
        ])
    }
    #[test]
    fn accepts_complete_regular_payload() {
        let data = fixture(b"/usr/bin/demo\n", "root/usr/bin/demo", b'0');
        let p = parse_tar(&data).unwrap();
        assert_eq!(p.name, "demo");
        assert_eq!(p.files["usr/bin/demo"].data, b"hello\n");
    }
    #[test]
    fn rejects_omitted_and_extra_file_list_entries() {
        for files in [
            b"".as_slice(),
            b"/usr/bin/demo\n/usr/bin/extra\n",
            b"/usr/bin/demo\n/usr/bin/demo\n",
        ] {
            assert!(parse_tar(&fixture(files, "root/usr/bin/demo", b'0')).is_err());
        }
    }
    #[test]
    fn rejects_traversal_absolute_reserved_and_link_entries() {
        for path in [
            "root/usr/../etc/demo",
            "/root/usr/bin/demo",
            "root/var/lib/mpkg/demo",
            "root/tmp/demo",
        ] {
            assert!(parse_tar(&fixture(b"/usr/bin/demo\n", path, b'0')).is_err());
        }
        for kind in [b'1', b'2', b'3', b'4', b'6', b'x', b'L'] {
            assert!(parse_tar(&fixture(b"/usr/bin/demo\n", "root/usr/bin/demo", kind)).is_err());
        }
    }
    #[test]
    fn rejects_duplicate_members_and_non_directory_ancestors() {
        let meta = [
            ("manifest", b'0', b"name=demo\nversion=1\n".as_slice()),
            ("files", b'0', b"/usr/bin/demo\n".as_slice()),
        ];
        for extra in [
            vec![
                ("root/usr/bin/demo", b'0', b"x".as_slice()),
                ("root/usr/bin/demo", b'0', b"y".as_slice()),
            ],
            vec![
                ("root/usr/bin", b'0', b"x".as_slice()),
                ("root/usr/bin/demo", b'0', b"y".as_slice()),
            ],
        ] {
            assert!(parse_tar(&archive(&[meta.to_vec(), extra].concat())).is_err());
        }
    }
    #[test]
    fn rejects_corruption_truncation_and_trailing_payload() {
        let data = fixture(b"/usr/bin/demo\n", "root/usr/bin/demo", b'0');
        for size in [1, 511, 512, data.len() - 512, data.len() - 1] {
            assert!(parse_tar(&data[..size]).is_err());
        }
        let mut bad = data.clone();
        bad[0] ^= 1;
        assert!(parse_tar(&bad).is_err());
        let mut bad = data;
        let end = bad.len() - 1;
        bad[end] = 1;
        assert!(parse_tar(&bad).is_err());
    }
    #[test]
    fn install_records_ownership_and_refuses_overwrite_or_upgrade() {
        let root = Temp::new();
        let data = fixture(b"/usr/bin/demo\n", "root/usr/bin/demo", b'0');
        let mut p = parse_tar(&data).unwrap();
        install(&root.0, &p).unwrap();
        assert_eq!(fs::read(root.0.join("usr/bin/demo")).unwrap(), b"hello\n");
        assert_eq!(
            fs::read_to_string(root.0.join("var/lib/mpkg/demo/files")).unwrap(),
            "/usr/bin/demo\n"
        );
        assert!(install(&root.0, &p).is_err());
        p.name = "other".into();
        assert!(install(&root.0, &p).is_err());
        assert!(!root.0.join("var/lib/mpkg/other").exists());
        assert!(!root.0.join("var/lib/mpkg/.transaction").exists());
    }
    #[test]
    fn rejects_existing_parent_symlink_without_touching_target() {
        let root = Temp::new();
        let outside = Temp::new();
        std::os::unix::fs::symlink(&outside.0, root.0.join("usr")).unwrap();
        let data = fixture(b"/usr/bin/demo\n", "root/usr/bin/demo", b'0');
        assert!(install(&root.0, &parse_tar(&data).unwrap()).is_err());
        assert_eq!(fs::read_dir(&outside.0).unwrap().count(), 0);
    }
    #[test]
    fn interrupted_install_rolls_back_only_its_own_links() {
        let root = Temp::new();
        let db = root.0.join("var/lib/mpkg");
        let tx = db.join(".transaction");
        fs::create_dir_all(tx.join("payload/usr/bin")).unwrap();
        fs::create_dir_all(root.0.join("usr/bin")).unwrap();
        fs::write(tx.join("files"), "/usr/bin/ours\n/usr/bin/foreign\n").unwrap();
        fs::write(tx.join("installing"), "").unwrap();
        fs::write(tx.join("payload/usr/bin/ours"), "ours").unwrap();
        fs::write(tx.join("payload/usr/bin/foreign"), "staged").unwrap();
        fs::hard_link(tx.join("payload/usr/bin/ours"), root.0.join("usr/bin/ours")).unwrap();
        fs::write(root.0.join("usr/bin/foreign"), "keep").unwrap();
        recover(&root.0, &db).unwrap();
        assert!(!root.0.join("usr/bin/ours").exists());
        assert_eq!(
            fs::read_to_string(root.0.join("usr/bin/foreign")).unwrap(),
            "keep"
        );
        assert!(!tx.exists());
        let data = fixture(b"/usr/bin/demo\n", "root/usr/bin/demo", b'0');
        install(&root.0, &parse_tar(&data).unwrap()).unwrap();
    }
    #[test]
    fn unfinished_staging_does_not_remove_existing_files() {
        let root = Temp::new();
        let db = root.0.join("var/lib/mpkg");
        fs::create_dir_all(db.join(".transaction")).unwrap();
        fs::write(root.0.join("keep"), "keep").unwrap();
        recover(&root.0, &db).unwrap();
        assert!(root.0.join("keep").exists());
    }
}
