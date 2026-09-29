/* Run PostgreSQL commands as the dedicated account. This is NOT a setuid binary. */
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void die(const char *what) { perror(what); exit(1); }
static void directory(const char *path, uid_t uid, gid_t gid)
{
    struct stat st;
    if (mkdir(path, 0700) < 0 && errno != EEXIST) die(path);
    if (lstat(path, &st) < 0) die(path);
    if (!S_ISDIR(st.st_mode)) { fprintf(stderr, "%s is not a real directory\n", path); exit(1); }
    if (chown(path, uid, gid) < 0 || chmod(path, 0700) < 0) die(path);
}
int main(int argc, char **argv)
{
    if (argc < 2) { fputs("usage: postgres-user COMMAND [ARG...]\n", stderr); return 2; }
    struct passwd *pw = getpwnam("postgres");
    if (!pw || pw->pw_uid == 0 || pw->pw_gid == 0) { fputs("missing unprivileged postgres account\n", stderr); return 1; }
    if (geteuid() == 0) {
        directory("/var/lib/postgresql", pw->pw_uid, pw->pw_gid);
        directory("/run/postgresql", pw->pw_uid, pw->pw_gid);
        if (setgroups(0, NULL) < 0 || setgid(pw->pw_gid) < 0 || setuid(pw->pw_uid) < 0) die("drop PostgreSQL privileges");
    } else if (geteuid() != pw->pw_uid || getegid() != pw->pw_gid) {
        fputs("run as root or postgres\n", stderr); return 1;
    }
    umask(077);
    if (setenv("HOME", "/var/lib/postgresql", 1) < 0 ||
        setenv("PATH", "/usr/pgsql/bin:/bin:/usr/bin", 1) < 0 ||
        setenv("LD_LIBRARY_PATH", "/usr/pgsql/lib", 1) < 0 ||
        setenv("PGDATA", "/var/lib/postgresql/data", 1) < 0 ||
        setenv("PGHOST", "/run/postgresql", 1) < 0 ||
        setenv("PSQL_PAGER", "", 1) < 0 ||
        setenv("PGUSER", "postgres", 1) < 0 || setenv("PGDATABASE", "postgres", 1) < 0)
        die("PostgreSQL environment");
    if (chdir("/var/lib/postgresql") < 0) die("PostgreSQL home");
    execvp(argv[1], argv + 1);
    die(argv[1]);
}
