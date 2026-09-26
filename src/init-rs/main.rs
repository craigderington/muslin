//! Muslin PID 1, Rust implementation kept behaviorally aligned with init.c.

use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{self, Write};
use std::os::raw::{c_char, c_int, c_ulong, c_void};
use std::ptr;
use std::thread;
use std::time::Duration;

const SHELL: &str = "/bin/sh";
const RCS: &str = "/etc/init.d/rcS";

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
    loop {
        let result = unsafe { waitpid(pid, ptr::null_mut(), 0) };
        if result == pid || (result < 0 && io::Error::last_os_error().raw_os_error() != Some(4)) {
            return;
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

fn shutdown(command: c_int, message: &str) -> ! {
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

    mount_fs("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "");
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
    mount_fs("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "mode=0620,ptmxmode=0666");
    mount_fs("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");
    mount_fs("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");

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
