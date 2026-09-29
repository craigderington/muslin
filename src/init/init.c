/*
 * muslin-init — PID 1 for Muslin Linux.
 *
 * Responsibilities (and nothing else):
 *   1. mount the pseudo filesystems
 *   2. attach a real console so job control works
 *   3. run /etc/init.d/rcS once
 *   4. spawn a login shell and respawn it when it exits
 *   5. reap every orphan
 *   6. handle halt / poweroff / reboot (BusyBox signal conventions)
 *
 * Build: cc -static -Os -o init init.c   (cc = musl-gcc, or gcc on Alpine)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
#include <linux/magic.h>
#include <sys/vfs.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SHELL     "/bin/sh"
#define RCS       "/etc/init.d/rcS"
#define RCK       "/etc/init.d/rcK"
#define TAG       "\033[1;36m[init]\033[0m "

static sigset_t handled;
static char console_path[288] = "/dev/console";

static void say(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs(TAG, stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static void mnt(const char *src, const char *dst, const char *fs,
                unsigned long flags, const char *data)
{
    mkdir(dst, 0755);
    if (mount(src, dst, fs, flags, data) < 0 && errno != EBUSY)
        say("mount %s on %s failed: %s", fs, dst, strerror(errno));
}

static int read_file(const char *path, char *buf, size_t len)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    if (n < 0)
        return -1;
    buf[n] = '\0';
    buf[strcspn(buf, "\n")] = '\0';
    return (int)n;
}

static int cmdline_has(const char *key)
{
    char buf[1024], *tok, *save;
    if (read_file("/proc/cmdline", buf, sizeof buf) < 0)
        return 0;
    for (tok = strtok_r(buf, " ", &save); tok; tok = strtok_r(NULL, " ", &save))
        if (strcmp(tok, key) == 0)
            return 1;
    return 0;
}

static int cmdline_value(const char *prefix, char *value, size_t len)
{
    char buf[1024], *tok, *save;
    size_t prefix_len = strlen(prefix);
    if (read_file("/proc/cmdline", buf, sizeof buf) < 0)
        return 0;
    for (tok = strtok_r(buf, " ", &save); tok; tok = strtok_r(NULL, " ", &save)) {
        if (strncmp(tok, prefix, prefix_len) == 0) {
            snprintf(value, len, "%s", tok + prefix_len);
            return value[0] != '\0';
        }
    }
    return 0;
}

static void __attribute__((noreturn)) boot_failed(const char *what)
{
    say("MUSLIN_BOOT_FAILED %s: %s", what, strerror(errno));
    sync();
    reboot(RB_POWER_OFF);
    for (;;) pause();
}

/* Delete only the old RAM filesystem; never cross into the new disk or mounts. */
static void remove_old_root(const char *path, dev_t device)
{
    DIR *dir = opendir(path);
    if (!dir) boot_failed("read old root");
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char child[4096];
        if (snprintf(child, sizeof child, "%s/%s", path, entry->d_name) >= (int)sizeof child)
            boot_failed("old root path too long");
        struct stat st;
        if (lstat(child, &st) < 0) boot_failed("stat old root");
        if (st.st_dev != device) continue;
        if (S_ISDIR(st.st_mode)) {
            remove_old_root(child, device);
            if (rmdir(child) < 0) boot_failed("remove old directory");
        } else if (unlink(child) < 0) boot_failed("remove old file");
    }
    closedir(dir);
}

static void switch_to_disk_root(int stage2)
{
    char device[256], target[256];
    const char *moves[] = { "/proc", "/dev", "/run", "/tmp" };
    if (stage2 || !cmdline_value("muslin.root=", device, sizeof device)) return;
    struct stat old_root, next_init;
    struct statfs fs;
    if (stat("/", &old_root) < 0 || statfs("/", &fs) < 0 ||
        (fs.f_type != RAMFS_MAGIC && fs.f_type != TMPFS_MAGIC))
        boot_failed("initial root is not a RAM filesystem");
    mkdir("/newroot", 0755);
    if (mount(device, "/newroot", "ext4", 0, NULL) < 0) boot_failed("mount disk root");
    if (stat("/newroot/sbin/init", &next_init) < 0 || !S_ISREG(next_init.st_mode) ||
        access("/newroot/sbin/init", X_OK) < 0) boot_failed("invalid disk init");
    for (size_t i = 0; i < sizeof moves / sizeof *moves; i++) {
        snprintf(target, sizeof target, "/newroot%s", moves[i]);
        mkdir(target, 0755);
        if (mount(moves[i], target, NULL, MS_MOVE, NULL) < 0) boot_failed("move mount");
    }
    remove_old_root("/", old_root.st_dev);
    if (chdir("/newroot") < 0 || mount(".", "/", NULL, MS_MOVE, NULL) < 0 ||
        chroot(".") < 0 || chdir("/") < 0) boot_failed("switch root");
    char *argv[] = { "/sbin/init", "--stage2", NULL };
    execv(argv[0], argv);
    boot_failed("exec disk init");
}

static void persistence_test(void)
{
    const char *marker = "/var/lib/muslin/persisted";
    const char *state = "retained";
    if (access(marker, F_OK) < 0) {
        int fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd < 0) {
            say("create persistence marker failed: %s", strerror(errno));
            return;
        }
        const char data[] = "persistent\n";
        if (write(fd, data, sizeof data - 1) != (ssize_t)(sizeof data - 1) || fsync(fd) < 0)
            boot_failed("write persistence marker");
        close(fd);
        sync();
        state = "created";
    }
    printf("MUSLIN_PERSIST_OK state=%s\n", state);
    fflush(stdout);
}

/* /dev/console can't be a controlling tty; find the real one behind it. */
static void resolve_console(void)
{
    char buf[256], *last;
    if (read_file("/sys/class/tty/console/active", buf, sizeof buf) <= 0)
        return;
    last = strrchr(buf, ' ');
    last = last ? last + 1 : buf;
    if (*last)
        snprintf(console_path, sizeof console_path, "/dev/%s", last);
}

static void attach_stdio(const char *path, int ctty)
{
    int fd = open(path, O_RDWR | (ctty ? 0 : O_NOCTTY));
    if (fd < 0)
        return;
    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2)
        close(fd);
    if (ctty)
        ioctl(0, TIOCSCTTY, 1);
}

static pid_t spawn(char *const argv[], int interactive)
{
    pid_t pid = fork();
    if (pid != 0)
        return pid;

    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    setsid();
    if (interactive)
        attach_stdio(console_path, 1);
    execv(argv[0], argv);
    say("exec %s: %s", argv[0], strerror(errno));
    _exit(127);
}

static void set_hostname(void)
{
    char name[64];
    if (read_file("/etc/hostname", name, sizeof name) > 0)
        sethostname(name, strlen(name));
}

static double uptime(void)
{
    char buf[64];
    return read_file("/proc/uptime", buf, sizeof buf) > 0 ? strtod(buf, NULL) : -1;
}

static void reap_all(void)
{
    while (waitpid(-1, NULL, WNOHANG) > 0)
        ;
}

static void nap_ms(long ms)
{
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static void __attribute__((noreturn)) shutdown_system(int how, const char *what)
{
    if (access(RCK, X_OK) == 0) {
        char *args[] = { RCK, NULL };
        pid_t hook = spawn(args, 0);
        int status = 0, finished = hook < 0;
        for (int i = 0; !finished && i < 300; i++) {
            pid_t result = waitpid(hook, &status, WNOHANG);
            if (result == hook) {
                finished = 1;
                if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
                    say("shutdown hook failed");
            } else if (result < 0 && errno != EINTR) {
                finished = 1;
                say("wait for shutdown hook: %s", strerror(errno));
            } else nap_ms(100);
        }
        if (!finished) {
            say("shutdown hook timed out");
            kill(-hook, SIGKILL);
            kill(hook, SIGKILL);
        }
    }
    say("%s: stopping processes", what);
    kill(-1, SIGTERM);
    for (int i = 0; i < 20; i++) {  /* up to 2s grace */
        reap_all();
        nap_ms(100);
    }
    kill(-1, SIGKILL);
    reap_all();
    sync();
    say("%s", what);
    reboot(how);
    for (;;)
        pause();
}

int main(int argc, char **argv)
{
    if (getpid() != 1) {
        fprintf(stderr, "muslin-init: must run as PID 1\n");
        return 1;
    }

    /* PID 1 takes signals synchronously via sigwaitinfo(). */
    sigemptyset(&handled);
    int sigs[] = { SIGCHLD, SIGTERM, SIGUSR1, SIGUSR2, SIGINT, SIGPWR };
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++)
        sigaddset(&handled, sigs[i]);
    sigprocmask(SIG_BLOCK, &handled, NULL);
    reboot(RB_DISABLE_CAD);  /* Ctrl-Alt-Del -> SIGINT to us */

    int stage2 = argc > 1 && strcmp(argv[1], "--stage2") == 0;
    if (!stage2) {
        mnt("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
        mnt("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
        mnt("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "mode=0620,ptmxmode=0666");
        mnt("tmpfs", "/dev/shm", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
        mnt("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");
        mnt("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    }

    attach_stdio("/dev/console", 0);
    resolve_console();

    umask(022);
    setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin", 1);
    setenv("HOME", "/root", 1);
    setenv("TERM", "linux", 1);
    set_hostname();
    switch_to_disk_root(stage2);

    struct utsname u;
    uname(&u);
    say("Muslin Linux on %s %s (%s)", u.sysname, u.release, u.machine);

    if (access(RCS, X_OK) == 0) {
        char *rc[] = { RCS, NULL };
        pid_t pid = spawn(rc, 0);
        int status = 0;
        if (pid < 0) boot_failed("spawn rcS");
        pid_t waited;
        do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
        if (waited != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
            boot_failed("rcS failed");
    }

    double t = uptime();
    if (cmdline_has("muslin.selftest")) {
        printf("MUSLIN_SELFTEST_OK uptime=%.3fs\n", t);
        fflush(stdout);
        shutdown_system(RB_AUTOBOOT, "selftest done");
    }
    if (cmdline_has("muslin.persisttest")) {
        persistence_test();
        shutdown_system(RB_AUTOBOOT, "persistence test done");
    }
    if (cmdline_has("muslin.packagetest"))
        shutdown_system(RB_AUTOBOOT, "package test done");
    say("userspace ready in %.3fs (kernel + init)", t);

    char *sh[] = { "-sh", NULL };  /* leading '-' = login shell */
    pid_t shell = -1;

    for (;;) {
        if (shell < 0) {
            shell = fork();
            if (shell == 0) {
                sigset_t none;
                sigemptyset(&none);
                sigprocmask(SIG_SETMASK, &none, NULL);
                setsid();
                attach_stdio(console_path, 1);
                if (chdir("/root") < 0) { /* stay in / */ }
                execv(SHELL, sh);
                _exit(127);
            }
        }

        siginfo_t si;
        int sig = sigwaitinfo(&handled, &si);
        switch (sig) {
        case SIGCHLD: {
            pid_t p;
            while ((p = waitpid(-1, NULL, WNOHANG)) > 0)
                if (p == shell) {
                    shell = -1;
                    nap_ms(500);  /* don't spin if the shell is broken */
                }
            break;
        }
        case SIGUSR1:
            shutdown_system(RB_HALT_SYSTEM, "halt");
        case SIGUSR2:
        case SIGPWR:
            shutdown_system(RB_POWER_OFF, "poweroff");
        case SIGTERM:
        case SIGINT:
            shutdown_system(RB_AUTOBOOT, "reboot");
        default:
            break;
        }
    }
}
