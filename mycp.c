#define _GNU_SOURCE

/*
 * mycp - a low-level Linux file copy/backup proof of concept.
 *
 * File and directory I/O deliberately uses Linux syscalls rather than
 * stdio/readdir/fopen.  Formatting and argument parsing use libc helpers,
 * but all bytes and metadata travel through file descriptors.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/limits.h>
#include <linux/types.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef SYS_getdents64
#define SYS_getdents64 __NR_getdents64
#endif

#define DEFAULT_BUFFER (1024U * 1024U)
#define MAX_BUFFER (64U * 1024U * 1024U)
#define COPY_MODE 0777
#define PROGRESS_WIDTH 30U

struct options {
    size_t buffer_size;
    int recursive;
    int preserve;
    int progress;
    int verify;
    int resume;
    int info;
    int benchmark;
    int sync;
    int verbose;
    const char *log_path;
};

struct stats {
    uint64_t files;
    uint64_t bytes;
    uint64_t skipped;
    uint64_t verified;
    double elapsed;
};

struct linux_dirent64 {
    ino64_t d_ino;
    off64_t d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[];
};

static int log_fd = -1;

static int write_all(int fd, const void *data, size_t len);

static void usage(const char *name)
{
    const char *text =
        "Usage: mycp [OPTIONS] SOURCE DEST\n"
        "\n"
        "Low-level Linux file copy and backup utility.\n\n"
        "Options:\n"
        "  -r, --recursive       copy directories recursively\n"
        "  -b, --buffer SIZE     buffer size (e.g. 64K, 1M; default 1M)\n"
        "  -p, --preserve        preserve permission bits\n"
        "      --progress       show progress for regular files\n"
        "  -v, --verify          verify copied bytes\n"
        "      --resume          continue a partial destination\n"
        "  -i, --info            display source file information\n"
        "      --benchmark      print throughput statistics\n"
        "      --sync           skip files with identical size and mtime\n"
        "  -l, --log PATH        append operation log to PATH\n"
        "      --verbose        print each operation\n"
        "  -h, --help            display this help\n\n"
        "Examples:\n"
        "  mycp --preserve --verify backup.tar /backup/backup.tar\n"
        "  mycp -r --resume --progress /data /backup/data\n"
        "  mycp --sync -r -l /var/log/mycp.log /data /backup/data\n";
    (void)name;
    (void)write_all(STDOUT_FILENO, text, strlen(text));
}

static void die_usage(const char *message)
{
    char line[512];
    int n = snprintf(line, sizeof(line), "mycp: %s\n", message);
    if (n > 0) (void)write_all(STDERR_FILENO, line, (size_t)n);
    usage("mycp");
    exit(2);
}

static int write_all(int fd, const void *data, size_t len)
{
    const char *p = data;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) { errno = EIO; return -1; }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static void emit_log(const char *level, const char *operation, const char *path,
                     int error_number)
{
    if (log_fd < 0) return;
    struct timespec ts;
    syscall(SYS_clock_gettime, CLOCK_REALTIME, &ts);
    char line[PATH_MAX + 256];
    int n = snprintf(line, sizeof(line), "%lld.%03ld [%s] %s %s%s%s\n",
                     (long long)ts.tv_sec, ts.tv_nsec / 1000000L, level,
                     operation, path, error_number ? ": " : "",
                     error_number ? strerror(error_number) : "");
    if (n > 0) (void)write_all(log_fd, line, (size_t)n);
}

static double now_seconds(void)
{
    struct timespec ts;
    syscall(SYS_clock_gettime, CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static int parse_size(const char *text, size_t *value)
{
    char *end;
    unsigned long long number = strtoull(text, &end, 10);
    if (end == text || number == 0 || number > MAX_BUFFER) return -1;
    if (*end == 'K' || *end == 'k') number *= 1024ULL;
    else if (*end == 'M' || *end == 'm') number *= 1024ULL * 1024ULL;
    else if (*end == 'G' || *end == 'g') number *= 1024ULL * 1024ULL * 1024ULL;
    else if (*end != '\0') return -1;
    if (number == 0 || number > MAX_BUFFER) return -1;
    *value = (size_t)number;
    return 0;
}

static int open_ro(const char *path)
{
    return (int)syscall(SYS_openat, AT_FDCWD, path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW, 0);
}

static int open_dest(const char *path, int flags, mode_t mode)
{
    return (int)syscall(SYS_openat, AT_FDCWD, path, flags | O_CLOEXEC | O_NOFOLLOW, mode);
}

static int path_is_dir(const char *path, struct stat *st)
{
    int fd = open_ro(path);
    if (fd < 0) return -1;
    int result = (syscall(SYS_fstat, fd, st) == 0 && S_ISDIR(st->st_mode));
    int saved = errno;
    syscall(SYS_close, fd);
    errno = saved;
    return result ? 1 : 0;
}

static const char *base_name(const char *path)
{
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static int join_path(char *out, size_t size, const char *left, const char *right)
{
    int n = snprintf(out, size, "%s%s%s", left, (left[0] && left[strlen(left)-1] == '/') ? "" : "/", right);
    return n >= 0 && (size_t)n < size ? 0 : (errno = ENAMETOOLONG, -1);
}

static void show_info(const char *path, const struct stat *st)
{
    char line[512];
    int n = snprintf(line, sizeof(line),
                     "%s: type=%s size=%lld mode=%04o uid=%u gid=%u mtime=%lld\n",
                     path, S_ISDIR(st->st_mode) ? "directory" : "file",
                     (long long)st->st_size, st->st_mode & 07777,
                     st->st_uid, st->st_gid, (long long)st->st_mtime);
    if (n > 0) (void)write_all(STDOUT_FILENO, line, (size_t)n);
}

static void print_progress(const char *path, uint64_t done, uint64_t total)
{
    char line[PATH_MAX + 128];
    unsigned percent = total ? (unsigned)((done * 100ULL) / total) : 100U;
    if (percent > 100U) percent = 100U;

    unsigned filled = (percent * PROGRESS_WIDTH) / 100U;
    char bar[PROGRESS_WIDTH + 1U];
    for (unsigned i = 0; i < PROGRESS_WIDTH; i++) bar[i] = '-';
    if (filled == PROGRESS_WIDTH) {
        for (unsigned i = 0; i < PROGRESS_WIDTH; i++) bar[i] = '#';
    } else if (filled > 0) {
        for (unsigned i = 0; i < filled; i++) bar[i] = '#';
    }
    bar[PROGRESS_WIDTH] = '\0';

    int n = snprintf(line, sizeof(line), "\r[%s%u%%] %s (%llu/%llu bytes)", bar, percent,
                     path, (unsigned long long)done, (unsigned long long)total);
    if (n > 0) (void)write_all(STDERR_FILENO, line, (size_t)n);
}

static int verify_file(const char *source, const char *dest, size_t buffer_size)
{
    int a = open_ro(source), b = open_ro(dest);
    if (a < 0 || b < 0) { int e = errno; if (a >= 0) syscall(SYS_close, a); if (b >= 0) syscall(SYS_close, b); errno = e; return -1; }
    char *buf_a = malloc(buffer_size), *buf_b = malloc(buffer_size);
    if (!buf_a || !buf_b) { free(buf_a); free(buf_b); syscall(SYS_close, a); syscall(SYS_close, b); errno = ENOMEM; return -1; }
    int result = 0;
    for (;;) {
        ssize_t na = read(a, buf_a, buffer_size), nb = read(b, buf_b, buffer_size);
        if (na < 0 || nb < 0) { result = -1; break; }
        if (na != nb || (na > 0 && memcmp(buf_a, buf_b, (size_t)na) != 0)) { errno = EIO; result = -1; break; }
        if (na == 0) break;
    }
    free(buf_a); free(buf_b); syscall(SYS_close, a); syscall(SYS_close, b);
    return result;
}

static int prefix_matches(const char *source, const char *dest, off_t prefix,
                          size_t buffer_size)
{
    int a = open_ro(source), b = open_ro(dest);
    if (a < 0 || b < 0) { int e = errno; if (a >= 0) syscall(SYS_close, a); if (b >= 0) syscall(SYS_close, b); errno = e; return -1; }
    char *buf_a = malloc(buffer_size), *buf_b = malloc(buffer_size);
    if (!buf_a || !buf_b) { free(buf_a); free(buf_b); syscall(SYS_close, a); syscall(SYS_close, b); errno = ENOMEM; return -1; }
    off_t remaining = prefix;
    int result = 1;
    while (remaining > 0) {
        size_t want = remaining < (off_t)buffer_size ? (size_t)remaining : buffer_size;
        ssize_t na = read(a, buf_a, want), nb = read(b, buf_b, want);
        if (na < 0 || nb < 0) { result = -1; break; }
        if (na != nb || memcmp(buf_a, buf_b, (size_t)na) != 0) { result = 0; break; }
        if (na == 0) { result = 0; break; }
        remaining -= na;
    }
    free(buf_a); free(buf_b); syscall(SYS_close, a); syscall(SYS_close, b);
    return result;
}

static int copy_file(const char *source, const char *dest, const struct stat *source_st,
                     const struct options *opt, struct stats *stats)
{
    int in = open_ro(source);
    if (in < 0) { emit_log("ERROR", "open-source", source, errno); return -1; }
    struct stat dst_st;
    int dst_exists = (syscall(SYS_newfstatat, AT_FDCWD, dest, &dst_st, AT_SYMLINK_NOFOLLOW) == 0);
    if (dst_exists && S_ISDIR(dst_st.st_mode)) { errno = EISDIR; syscall(SYS_close, in); emit_log("ERROR", "open-destination", dest, errno); return -1; }
    int flags = O_WRONLY | O_CREAT | O_CLOEXEC;
    off_t start = 0;
    if (opt->resume && dst_exists && S_ISREG(dst_st.st_mode) && dst_st.st_size > 0 && dst_st.st_size < source_st->st_size) {
        int prefix_ok = prefix_matches(source, dest, dst_st.st_size, opt->buffer_size);
        if (prefix_ok < 0) { int e = errno; syscall(SYS_close, in); errno = e; return -1; }
        if (prefix_ok == 1) {
            start = dst_st.st_size;
            flags |= O_APPEND;
        } else {
            emit_log("WARN", "resume-prefix-mismatch-restart", dest, 0);
            flags |= O_TRUNC;
        }
    } else {
        flags |= O_TRUNC;
    }
    int out = open_dest(dest, flags, source_st->st_mode & 07777);
    if (out < 0) { int e = errno; syscall(SYS_close, in); emit_log("ERROR", "open-destination", dest, e); errno = e; return -1; }
    if (start && syscall(SYS_lseek, in, start, SEEK_SET) < 0) { int e = errno; syscall(SYS_close, in); syscall(SYS_close, out); errno = e; return -1; }
    char *buffer = malloc(opt->buffer_size);
    if (!buffer) { syscall(SYS_close, in); syscall(SYS_close, out); errno = ENOMEM; return -1; }
    uint64_t done = (uint64_t)start;
    double begin = now_seconds();
    if (opt->verbose) emit_log("INFO", start ? "resume" : "copy", source, 0);
    for (;;) {
        ssize_t n = read(in, buffer, opt->buffer_size);
        if (n < 0) { if (errno == EINTR) continue; break; }
        if (n == 0) break;
        if (write_all(out, buffer, (size_t)n) < 0) break;
        done += (uint64_t)n;
        if (opt->progress) print_progress(dest, done, (uint64_t)source_st->st_size);
    }
    int saved = errno;
    free(buffer);
    if (opt->progress) (void)write_all(STDERR_FILENO, "\n", 1);
    if (syscall(SYS_fsync, out) < 0 && saved == 0) saved = errno;
    if (opt->preserve && syscall(SYS_fchmod, out, source_st->st_mode & 07777) < 0 && saved == 0) saved = errno;
    syscall(SYS_close, in); syscall(SYS_close, out);
    if (done != (uint64_t)source_st->st_size) { errno = saved ? saved : EIO; emit_log("ERROR", "copy", dest, errno); return -1; }
    stats->bytes += done - (uint64_t)start;
    stats->files++;
    if (opt->verify) {
        if (verify_file(source, dest, opt->buffer_size) < 0) { emit_log("ERROR", "verify", dest, errno); return -1; }
        stats->verified++;
    }
    stats->elapsed += now_seconds() - begin;
    emit_log("INFO", "complete", dest, 0);
    return 0;
}

static int copy_tree(const char *source, const char *dest, const struct options *opt, struct stats *stats)
{
    struct stat st;
    int source_fd = open_ro(source);
    if (source_fd < 0) { emit_log("ERROR", "open-source", source, errno); return -1; }
    if (syscall(SYS_fstat, source_fd, &st) < 0) { int e = errno; syscall(SYS_close, source_fd); errno = e; return -1; }
    if (!S_ISDIR(st.st_mode)) {
        syscall(SYS_close, source_fd);
        if (opt->info) show_info(source, &st);
        return copy_file(source, dest, &st, opt, stats);
    }
    syscall(SYS_close, source_fd);
    if (!opt->recursive) { errno = EISDIR; emit_log("ERROR", "directory-requires--r", source, errno); return -1; }
    struct stat dest_st;
    int dest_dir = path_is_dir(dest, &dest_st);
    if (dest_dir < 0) {
        if (errno != ENOENT) return -1;
        if (syscall(SYS_mkdir, dest, (st.st_mode & 07777) | 0700) < 0 && errno != EEXIST) return -1;
    }
    int dirfd = open_dest(source, O_RDONLY | O_DIRECTORY, 0);
    if (dirfd < 0) return -1;
    char *entries = malloc(opt->buffer_size < 65536 ? 65536 : opt->buffer_size);
    if (!entries) { syscall(SYS_close, dirfd); errno = ENOMEM; return -1; }
    size_t entries_size = opt->buffer_size < 65536 ? 65536 : opt->buffer_size;
    for (;;) {
        int n = (int)syscall(SYS_getdents64, dirfd, entries, entries_size);
        if (n == 0) break;
        if (n < 0) { free(entries); syscall(SYS_close, dirfd); return -1; }
        for (int off = 0; off < n;) {
            struct linux_dirent64 *entry = (struct linux_dirent64 *)(entries + off);
            if (entry->d_reclen < offsetof(struct linux_dirent64, d_name) + 1) { errno = EIO; free(entries); syscall(SYS_close, dirfd); return -1; }
            if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
                char src_child[PATH_MAX], dst_child[PATH_MAX];
                if (join_path(src_child, sizeof(src_child), source, entry->d_name) < 0 || join_path(dst_child, sizeof(dst_child), dest, entry->d_name) < 0) { free(entries); syscall(SYS_close, dirfd); return -1; }
                struct stat child_st;
                if (syscall(SYS_newfstatat, dirfd, entry->d_name, &child_st, AT_SYMLINK_NOFOLLOW) < 0) { free(entries); syscall(SYS_close, dirfd); return -1; }
                if (opt->info) show_info(src_child, &child_st);
                if (S_ISDIR(child_st.st_mode)) {
                    if (copy_tree(src_child, dst_child, opt, stats) < 0) { free(entries); syscall(SYS_close, dirfd); return -1; }
                } else if (S_ISREG(child_st.st_mode)) {
                    if (opt->sync) {
                        struct stat old;
                        if (syscall(SYS_newfstatat, AT_FDCWD, dst_child, &old, AT_SYMLINK_NOFOLLOW) == 0 && old.st_size == child_st.st_size && old.st_mtime == child_st.st_mtime) { stats->skipped++; off += entry->d_reclen; continue; }
                    }
                    if (copy_file(src_child, dst_child, &child_st, opt, stats) < 0) { free(entries); syscall(SYS_close, dirfd); return -1; }
                    if (opt->preserve) (void)syscall(SYS_chmod, dst_child, child_st.st_mode & 07777);
                }
            }
            off += entry->d_reclen;
        }
    }
    free(entries); syscall(SYS_close, dirfd);
    if (opt->preserve) (void)syscall(SYS_chmod, dest, st.st_mode & 07777);
    return 0;
}

int main(int argc, char **argv)
{
    struct options opt = { .buffer_size = DEFAULT_BUFFER, .progress = 1 };
    const char *source = NULL, *dest = NULL;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "-r") == 0 || strcmp(arg, "--recursive") == 0) opt.recursive = 1;
        else if (strcmp(arg, "-p") == 0 || strcmp(arg, "--preserve") == 0) opt.preserve = 1;
        else if (strcmp(arg, "--progress") == 0) opt.progress = 1;
        else if (strcmp(arg, "-v") == 0 || strcmp(arg, "--verify") == 0) opt.verify = 1;
        else if (strcmp(arg, "--resume") == 0) opt.resume = 1;
        else if (strcmp(arg, "-i") == 0 || strcmp(arg, "--info") == 0) opt.info = 1;
        else if (strcmp(arg, "--benchmark") == 0) opt.benchmark = 1;
        else if (strcmp(arg, "--sync") == 0) opt.sync = 1;
        else if (strcmp(arg, "--verbose") == 0) opt.verbose = 1;
        else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) { usage(argv[0]); return 0; }
        else if (strcmp(arg, "-b") == 0 || strcmp(arg, "--buffer") == 0) {
            if (++i >= argc || parse_size(argv[i], &opt.buffer_size) < 0) die_usage("invalid buffer size");
        } else if (strcmp(arg, "-l") == 0 || strcmp(arg, "--log") == 0) {
            if (++i >= argc) die_usage("--log requires a path");
            opt.log_path = argv[i];
        } else if (arg[0] == '-' && arg[1] != '\0') die_usage("unknown option");
        else if (!source) source = arg;
        else if (!dest) dest = arg;
        else die_usage("expected exactly SOURCE and DEST");
    }
    if (!source || !dest) die_usage("SOURCE and DEST are required");
    if (opt.log_path) {
        log_fd = open_dest(opt.log_path, O_WRONLY | O_CREAT | O_APPEND, 0640);
        if (log_fd < 0) { perror("mycp: log"); return 1; }
    }
    struct stat source_st;
    int source_type = path_is_dir(source, &source_st);
    if (source_type < 0) { perror("mycp: source"); return 1; }
    char final_dest[PATH_MAX];
    if (path_is_dir(dest, &(struct stat){0}) == 1) {
        if (join_path(final_dest, sizeof(final_dest), dest, base_name(source)) < 0) { perror("mycp: destination"); return 1; }
    } else {
        if (strlen(dest) >= sizeof(final_dest)) { errno = ENAMETOOLONG; perror("mycp: destination"); return 1; }
        strcpy(final_dest, dest);
    }
    if (opt.info && source_type == 1) show_info(source, &source_st);
    struct stats stats = {0};
    double begin = now_seconds();
    int result = copy_tree(source, final_dest, &opt, &stats);
    double elapsed = now_seconds() - begin;
    if (result < 0) {
        int e = errno;
        emit_log("ERROR", "operation-failed", source, e);
        char line[512]; int n = snprintf(line, sizeof(line), "mycp: %s -> %s: %s\n", source, final_dest, strerror(e));
        if (n > 0) (void)write_all(STDERR_FILENO, line, (size_t)n);
        if (log_fd >= 0) syscall(SYS_close, log_fd);
        return 1;
    }
    if (opt.benchmark) {
        double mbps = elapsed > 0.0 ? ((double)stats.bytes / (1024.0 * 1024.0)) / elapsed : 0.0;
        char line[512]; int n = snprintf(line, sizeof(line), "mycp: files=%llu bytes=%llu skipped=%llu verified=%llu time=%.3fs throughput=%.2f MiB/s\n", (unsigned long long)stats.files, (unsigned long long)stats.bytes, (unsigned long long)stats.skipped, (unsigned long long)stats.verified, elapsed, mbps);
        if (n > 0) (void)write_all(STDOUT_FILENO, line, (size_t)n);
    }
    if (log_fd >= 0) syscall(SYS_close, log_fd);
    return 0;
}
