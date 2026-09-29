//! Muslin PID 1, Rust implementation kept behaviorally aligned with init.c.

use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::raw::{c_char, c_int, c_ulong, c_void};
use std::ptr;
use std::thread;
use std::time::Duration;

const SHELL: &str = "/bin/sh";
const RCS: &str = "/etc/init.d/rcS";
const RCK: &str = "/etc/init.d/rcK";

const O_RDWR: c_int = 2;
const O_NOCTTY: c_int = 0x100;
const SIG_BLOCK: c_int = 0;
const SIG_SETMASK: c_int = 2;
const WNOHANG: c_int = 1;
const TIOCSCTTY: c_ulong = 0x540e;

const SIGINT: c_int = 2;
const SIGCHLD: c_int = 17;
const SIGTERM: c_int = 15;
const SIGUSR1: c_int = 10;
const SIGUSR2: c_int = 12;
const SIGPWR: c_int = 30;
const SIGKILL: c_int = 9;

const RB_DISABLE_CAD: c_int = 0;
const RB_AUTOBOOT: c_int = 0x0123_4567;
const RB_HALT_SYSTEM: c_int = 0xcdef_0123_u32 as c_int;
const RB_POWER_OFF: c_int = 0x4321_fedc;

const MS_NOSUID: c_ulong = 2;
const MS_NODEV: c_ulong = 4;
const MS_NOEXEC: c_ulong = 8;
const MS_MOVE: c_ulong = 8192;

#[repr(C)]
struct SigSet {
    bits: [u64; 16],
}

extern "C" {
    fn getpid() -> c_int;
    fn mount(
        source: *const c_char,
        target: *const c_char,
        filesystem: *const c_char,
        flags: c_ulong,
        data: *const c_void,
    ) -> c_int;
    fn open(path: *const c_char, flags: c_int, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn dup2(oldfd: c_int, newfd: c_int) -> c_int;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
    fn fork() -> c_int;
    fn setsid() -> c_int;
    fn chdir(path: *const c_char) -> c_int;
    fn chroot(path: *const c_char) -> c_int;
    fn execv(path: *const c_char, argv: *const *const c_char) -> c_int;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
    fn kill(pid: c_int, signal: c_int) -> c_int;
    fn sync();
    fn reboot(command: c_int) -> c_int;
    fn sethostname(name: *const c_char, len: usize) -> c_int;
    fn umask(mask: u32) -> u32;
    fn sigemptyset(set: *mut SigSet) -> c_int;
    fn sigaddset(set: *mut SigSet, signal: c_int) -> c_int;
    fn sigprocmask(how: c_int, set: *const SigSet, old: *mut SigSet) -> c_int;
    fn sigwait(set: *const SigSet, signal: *mut c_int) -> c_int;
}

fn say(message: &str) {
    eprintln!("\x1b[1;35m[init-rs]\x1b[0m {message}");
}

fn cstring(value: &str) -> CString {
    CString::new(value).expect("path contains NUL")
}

fn mount_fs(source: &str, target: &str, filesystem: &str, flags: c_ulong, data: &str) {
    let _ = fs::create_dir_all(target);
    let source = cstring(source);
    let target = cstring(target);
    let filesystem = cstring(filesystem);
    let data = cstring(data);
    let result = unsafe {
        mount(
            source.as_ptr(),
            target.as_ptr(),
            filesystem.as_ptr(),
            flags,
            data.as_ptr().cast(),
        )
    };
    if result < 0 && io::Error::last_os_error().raw_os_error() != Some(16) {
        say(&format!("mount {filesystem:?} on {target:?} failed: {}", io::Error::last_os_error()));
    }
}

fn console_path() -> String {
    fs::read_to_string("/sys/class/tty/console/active")
        .ok()
        .and_then(|active| active.split_whitespace().last().map(str::to_owned))
        .map(|name| format!("/dev/{name}"))
        .unwrap_or_else(|| "/dev/console".to_owned())
}

fn attach_stdio(path: &str, controlling: bool) {
    let path = cstring(path);
    let flags = O_RDWR | if controlling { 0 } else { O_NOCTTY };
    let fd = unsafe { open(path.as_ptr(), flags) };
    if fd < 0 {
        return;
    }
    for target in 0..=2 {
        unsafe { dup2(fd, target) };
    }
    if fd > 2 {
        unsafe { close(fd) };
    }
    if controlling {
        unsafe { ioctl(0, TIOCSCTTY, 1) };
    }
}

fn reset_signal_mask() {
    let mut empty = SigSet { bits: [0; 16] };
    unsafe {
        sigemptyset(&mut empty);
        sigprocmask(SIG_SETMASK, &empty, ptr::null_mut());
    }
}

fn spawn(path: &str, arguments: &[&str], console: Option<&str>, workdir: Option<&str>) -> c_int {
    let pid = unsafe { fork() };
    if pid != 0 {
        return pid;
    }
    reset_signal_mask();
    unsafe { setsid() };
    if let Some(console) = console {
        attach_stdio(console, true);
    }
    if let Some(workdir) = workdir {
        let workdir = cstring(workdir);
        unsafe { chdir(workdir.as_ptr()) };
    }
    let path = cstring(path);
    let arguments: Vec<CString> = arguments.iter().map(|value| cstring(value)).collect();
    let mut argv: Vec<*const c_char> = arguments.iter().map(|value| value.as_ptr()).collect();
    argv.push(ptr::null());
    unsafe { execv(path.as_ptr(), argv.as_ptr()) };
    unsafe { libc_exit(127) }
}

#[inline(always)]
unsafe fn libc_exit(code: c_int) -> ! {
    extern "C" {
        fn _exit(code: c_int) -> !;
    }
    _exit(code)
}

fn wait_for(pid: c_int) {
    if pid < 0 { boot_failed("spawn rcS"); }
    loop {
        let mut status = 0;
        let result = unsafe { waitpid(pid, &mut status, 0) };
        if result == pid {
            if status != 0 { boot_failed("rcS failed"); }
            return;
        }
        if result < 0 && io::Error::last_os_error().raw_os_error() != Some(4) {
            boot_failed("wait for rcS");
        }
    }
}

fn reap(shell: &mut c_int) {
    loop {
        let pid = unsafe { waitpid(-1, ptr::null_mut(), WNOHANG) };
        if pid <= 0 {
            return;
        }
        if pid == *shell {
            *shell = -1;
            thread::sleep(Duration::from_millis(500));
        }
    }
}

fn uptime() -> f64 {
    fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|value| value.split_whitespace().next()?.parse().ok())
        .unwrap_or(-1.0)
}

fn cmdline_value(prefix: &str) -> Option<String> {
    fs::read_to_string("/proc/cmdline")
        .ok()?
        .split_whitespace()
        .find_map(|argument| argument.strip_prefix(prefix).map(str::to_owned))
        .filter(|value| !value.is_empty())
}

fn boot_failed(what: &str) -> ! {
    say(&format!("MUSLIN_BOOT_FAILED {what}: {}", io::Error::last_os_error()));
    unsafe { sync(); reboot(RB_POWER_OFF); }
    loop { thread::park(); }
}

fn remove_old_root(path: &std::path::Path, device: u64) -> io::Result<()> {
    for entry in fs::read_dir(path)? {
        let path = entry?.path();
        let meta = fs::symlink_metadata(&path)?;
        if meta.dev() != device { continue; }
        if meta.is_dir() {
            remove_old_root(&path, device)?;
            fs::remove_dir(path)?;
        } else {
            fs::remove_file(path)?;
        }
    }
    Ok(())
}

fn switch_to_disk_root(stage2: bool) {
    if stage2 { return; }
    let Some(device) = cmdline_value("muslin.root=") else { return; };
    // Verify the initial root is RAM-backed before deleting any of its files.
    let mountinfo = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    let ram_root = mountinfo.lines().any(|line| {
        let Some((mount, kind)) = line.split_once(" - ") else { return false; };
        mount.split_whitespace().nth(4) == Some("/")
            && matches!(kind.split_whitespace().next(), Some("rootfs" | "ramfs" | "tmpfs"))
    });
    if !ram_root { boot_failed("initial root is not a RAM filesystem"); }
    let old_device = fs::metadata("/").unwrap_or_else(|_| boot_failed("stat old root")).dev();
    let _ = fs::create_dir_all("/newroot");
    let device = cstring(&device);
    let newroot = cstring("/newroot");
    let ext4 = cstring("ext4");
    if unsafe { mount(device.as_ptr(), newroot.as_ptr(), ext4.as_ptr(), 0, ptr::null()) } < 0 {
        boot_failed("mount disk root");
    }
    let init_meta = fs::metadata("/newroot/sbin/init").unwrap_or_else(|_| boot_failed("missing disk init"));
    if !init_meta.is_file() || init_meta.permissions().mode() & 0o111 == 0 { boot_failed("invalid disk init"); }
    for source in ["/proc", "/dev", "/run", "/tmp"] {
        let target = format!("/newroot{source}");
        let _ = fs::create_dir_all(&target);
        let source = cstring(source);
        let target = cstring(&target);
        if unsafe { mount(source.as_ptr(), target.as_ptr(), ptr::null(), MS_MOVE, ptr::null()) } < 0 {
            boot_failed("move mount");
        }
    }
    remove_old_root(std::path::Path::new("/"), old_device).unwrap_or_else(|_| boot_failed("remove old root"));
    let dot = cstring(".");
    let slash = cstring("/");
    let init = cstring("/sbin/init");
    let stage2_arg = cstring("--stage2");
    unsafe {
        if chdir(newroot.as_ptr()) < 0
            || mount(dot.as_ptr(), slash.as_ptr(), ptr::null(), MS_MOVE, ptr::null()) < 0
            || chroot(dot.as_ptr()) < 0 || chdir(slash.as_ptr()) < 0
        { boot_failed("switch root"); }
        let argv = [init.as_ptr(), stage2_arg.as_ptr(), ptr::null()];
        execv(init.as_ptr(), argv.as_ptr());
    }
    boot_failed("exec disk init");
}

fn persistence_test() {
    let marker = "/var/lib/muslin/persisted";
    let state = if fs::metadata(marker).is_ok() {
        "retained"
    } else {
        match OpenOptions::new().write(true).create(true).truncate(true).open(marker) {
            Ok(mut file) => {
                file.write_all(b"persistent\n").unwrap_or_else(|_| boot_failed("write persistence marker"));
                file.sync_all().unwrap_or_else(|_| boot_failed("sync persistence marker"));
                unsafe { sync() };
                "created"
            }
            Err(error) => {
                say(&format!("create persistence marker failed: {error}"));
                "failed"
            }
        }
    };
    println!("MUSLIN_PERSIST_OK state={state}");
    let _ = io::stdout().flush();
}

fn shutdown(command: c_int, message: &str) -> ! {
    if fs::metadata(RCK).is_ok() {
        let hook = spawn(RCK, &[RCK], None, None);
        let mut finished = hook < 0;
        for _ in 0..300 {
            if finished { break; }
            let mut status = 0;
            let result = unsafe { waitpid(hook, &mut status, WNOHANG) };
            if result == hook {
                finished = true;
                if status != 0 { say("shutdown hook failed"); }
            } else if result < 0 && io::Error::last_os_error().raw_os_error() != Some(4) {
                say("wait for shutdown hook failed");
                finished = true;
            } else {
                thread::sleep(Duration::from_millis(100));
            }
        }
        if !finished {
            say("shutdown hook timed out");
            unsafe { kill(-hook, SIGKILL); kill(hook, SIGKILL); }
        }
    }
    say(&format!("{message}: stopping processes"));
    unsafe { kill(-1, SIGTERM) };
    let mut shell = -1;
    for _ in 0..20 {
        reap(&mut shell);
        thread::sleep(Duration::from_millis(100));
    }
    unsafe {
        kill(-1, SIGKILL);
        sync();
    }
    say(message);
    unsafe { reboot(command) };
    loop {
        thread::park();
    }
}

fn main() {
    if unsafe { getpid() } != 1 {
        eprintln!("muslin-init-rs: must run as PID 1");
        std::process::exit(1);
    }

    let mut handled = SigSet { bits: [0; 16] };
    unsafe {
        sigemptyset(&mut handled);
        for signal in [SIGCHLD, SIGTERM, SIGUSR1, SIGUSR2, SIGINT, SIGPWR] {
            sigaddset(&mut handled, signal);
        }
        sigprocmask(SIG_BLOCK, &handled, ptr::null_mut());
        reboot(RB_DISABLE_CAD);
    }

    let stage2 = env::args().any(|argument| argument == "--stage2");
    if !stage2 {
        mount_fs("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "");
        mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
        mount_fs("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "mode=0620,ptmxmode=0666");
        mount_fs("tmpfs", "/dev/shm", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
        mount_fs("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");
        mount_fs("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    }

    attach_stdio("/dev/console", false);
    let console = console_path();
    unsafe { umask(0o022) };
    env::set_var("PATH", "/bin:/sbin:/usr/bin:/usr/sbin");
    env::set_var("HOME", "/root");
    env::set_var("TERM", "linux");
    if let Ok(hostname) = fs::read_to_string("/etc/hostname") {
        let hostname = hostname.trim();
        unsafe { sethostname(hostname.as_ptr().cast(), hostname.len()) };
    }
    switch_to_disk_root(stage2);

    let release = fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default();
    say(&format!("Muslin Linux on Linux {} ({})", release.trim(), env::consts::ARCH));

    if fs::metadata(RCS).is_ok() {
        wait_for(spawn(RCS, &[RCS], None, None));
    }

    let elapsed = uptime();
    let selftest = fs::read_to_string("/proc/cmdline")
        .unwrap_or_default()
        .split_whitespace()
        .any(|argument| argument == "muslin.selftest");
    if selftest {
        println!("MUSLIN_SELFTEST_OK init=rust uptime={elapsed:.3}s");
        let _ = io::stdout().flush();
        shutdown(RB_AUTOBOOT, "selftest done");
    }
    if fs::read_to_string("/proc/cmdline")
        .unwrap_or_default()
        .split_whitespace()
        .any(|argument| argument == "muslin.persisttest")
    {
        persistence_test();
        shutdown(RB_AUTOBOOT, "persistence test done");
    }
    if fs::read_to_string("/proc/cmdline")
        .unwrap_or_default()
        .split_whitespace()
        .any(|argument| argument == "muslin.packagetest")
    {
        shutdown(RB_AUTOBOOT, "package test done");
    }
    say(&format!("userspace ready in {elapsed:.3}s (kernel + init-rs)"));

    let mut shell = -1;
    loop {
        if shell < 0 {
            shell = spawn(SHELL, &["-sh"], Some(&console), Some("/root"));
        }
        let mut signal = 0;
        if unsafe { sigwait(&handled, &mut signal) } != 0 {
            continue;
        }
        match signal {
            SIGCHLD => reap(&mut shell),
            SIGUSR1 => shutdown(RB_HALT_SYSTEM, "halt"),
            SIGUSR2 | SIGPWR => shutdown(RB_POWER_OFF, "poweroff"),
            SIGTERM | SIGINT => shutdown(RB_AUTOBOOT, "reboot"),
            _ => {}
        }
    }
}
