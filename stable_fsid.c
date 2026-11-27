/*
 * UNFS3 stable filesystem IDs (Linux)
 * see file LICENSE for license details
 *
 * unfsd puts st_dev into every file handle and reports it as the NFS fsid.
 * Network and other virtual filesystems such as CIFS get an anonymous device
 * number from the kernel when they are mounted, so the number depends on mount
 * order and can change across a reboot. Every file handle then goes stale and
 * clients that stored handles see a different filesystem.
 *
 * With -S, st_dev is replaced by an ID that does not depend on mount order,
 * in the one place all file metadata passes through (the stat family), so file
 * handles, caches, path resolution and attributes all agree.
 *
 *   -S auto               ID = hash of the CIFS/SMB3 server path (lower-cased,
 *                         as SMB names ignore case) and the mounted subtree
 *   -S <mountpoint>=<id>  fixed ID for that mounted filesystem (any type)
 *
 * IDs are in 0x40000000-0x7fffffff: clear of the kernel's device numbers in
 * practice, and of the IDs unfsd gives export points (top bit set).
 */

#include "config.h"

#ifdef __linux__

#include <ctype.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <sys/sysmacros.h>

#include "stable_fsid.h"

#define SFSID_MAX 256
#define SFSID_BASE 0x40000000U
#define SFSID_MASK 0x3fffffffU

extern int opt_detach;
void logmsg(int prio, const char *fmt, ...);

static int sfsid_auto = 0;
static struct {
    char dir[PATH_MAX];
    unsigned int id;
} manual[SFSID_MAX];
static int nmanual = 0;
static struct {
    dev_t dev;
    unsigned int id;
} map[SFSID_MAX];
static int nmap = 0;
static int mounts_fd = -1;
static int loaded = 0;
static int check_mounts = 1;

void sfsid_enable_auto(void)
{
    sfsid_auto = 1;
}

int sfsid_add_manual(const char *spec)
{
    const char *eq = strrchr(spec, '=');
    char *end;
    unsigned long id;
    size_t len;

    if (!eq || spec[0] != '/' || nmanual >= SFSID_MAX)
        return -1;
    id = strtoul(eq + 1, &end, 0);
    if (end == eq + 1 || *end != '\0' || id > SFSID_MASK)
        return -1;
    len = eq - spec;
    while (len > 1 && spec[len - 1] == '/')
        len--;
    if (len >= PATH_MAX)
        return -1;
    memcpy(manual[nmanual].dir, spec, len);
    manual[nmanual].dir[len] = '\0';
    manual[nmanual].id = SFSID_BASE | (unsigned int) id;
    nmanual++;
    return 0;
}

static unsigned int hash_str(unsigned int h, const char *s, int fold)
{
    for (; *s; s++) {
        h ^= (unsigned char) (fold ? tolower((unsigned char) *s) : *s);
        h *= 0x01000193U;
    }
    return h;
}

/* decode the \040-style escapes used in /proc/self/mountinfo */
static void unescape(char *s)
{
    char *o = s;

    while (*s) {
        if (s[0] == '\\' && s[1] >= '0' && s[1] <= '3' && s[2] && s[3]) {
            *o++ = (char) (((s[1] - '0') << 6) | ((s[2] - '0') << 3) |
                           (s[3] - '0'));
            s += 4;
        } else
            *o++ = *s++;
    }
    *o = '\0';
}

static void add_mapping(dev_t dev, unsigned int id, const char *what)
{
    int i;

    for (i = 0; i < nmap; i++) {
        if (map[i].dev == dev)
            return;             /* first match wins (manual pass runs first) */
        if (map[i].id == id) {
            logmsg(LOG_CRIT,
                   "stable fsid: %s would get the same ID 0x%08x as another "
                   "mount; keeping its device number", what, id);
            return;
        }
    }
    if (nmap < SFSID_MAX) {
        map[nmap].dev = dev;
        map[nmap].id = id;
        nmap++;
        logmsg(LOG_INFO, "stable fsid: %s (device %u:%u) is 0x%08x", what,
               major(dev), minor(dev), id);
    }
}

/* rebuild the device-to-ID table from the current mount table */
static void load_mounts(void)
{
    FILE *f;
    char *line = NULL;
    size_t cap = 0;
    int pass, i;

    nmap = 0;
    loaded = 1;
    for (pass = 0; pass < 2; pass++) {
        f = fopen("/proc/self/mountinfo", "r");
        if (!f) {
            logmsg(LOG_CRIT, "stable fsid: cannot read the mount table");
            break;
        }
        while (getline(&line, &cap, f) != -1) {
            unsigned int ma, mi;
            char root[PATH_MAX], dir[PATH_MAX], type[64], src[PATH_MAX];
            char *sep = strstr(line, " - ");

            if (!sep ||
                sscanf(line, "%*u %*u %u:%u %4095s %4095s", &ma, &mi, root,
                       dir) != 4 ||
                sscanf(sep + 3, "%63s %4095s", type, src) != 2)
                continue;
            unescape(root);
            unescape(dir);
            unescape(src);
            if (pass == 0) {
                for (i = 0; i < nmanual; i++)
                    if (strcmp(dir, manual[i].dir) == 0)
                        add_mapping(makedev(ma, mi), manual[i].id, dir);
            } else if (sfsid_auto && (strcmp(type, "cifs") == 0 ||
                                      strcmp(type, "smb3") == 0)) {
                unsigned int h = hash_str(0x811c9dc5U, src, 1);

                h = hash_str(h, "\n", 0);
                h = hash_str(h, root, 1);
                add_mapping(makedev(ma, mi), SFSID_BASE | (h & SFSID_MASK),
                            src);
            }
        }
        fclose(f);
    }
    free(line);
}

/* the kernel flags /proc/self/mountinfo with POLLPRI when mounts change */
static int mounts_changed(void)
{
    struct pollfd p;

    if (mounts_fd < 0) {
        mounts_fd = open("/proc/self/mountinfo", O_RDONLY | O_CLOEXEC);
        return 1;
    }
    p.fd = mounts_fd;
    p.events = POLLPRI;
    p.revents = 0;
    return poll(&p, 1, 0) > 0 && (p.revents & (POLLPRI | POLLERR));
}

static void translate(struct stat *buf)
{
    int i;

    if (!sfsid_auto && nmanual == 0)
        return;
    /* one poll() per request, not per stat: a tree walk stats thousands
       of entries within a single request */
    if (check_mounts || !loaded) {
        check_mounts = 0;
        if (mounts_changed() || !loaded)
            load_mounts();
    }
    for (i = 0; i < nmap; i++)
        if (map[i].dev == buf->st_dev) {
            buf->st_dev = map[i].id;
            return;
        }
}

void sfsid_new_request(void)
{
    check_mounts = 1;
}

int sfsid_stat(const char *path, struct stat *buf)
{
    int res = stat(path, buf);

    if (res == 0)
        translate(buf);
    return res;
}

int sfsid_lstat(const char *path, struct stat *buf)
{
    int res = lstat(path, buf);

    if (res == 0)
        translate(buf);
    return res;
}

int sfsid_fstat(int fd, struct stat *buf)
{
    int res = fstat(fd, buf);

    if (res == 0)
        translate(buf);
    return res;
}

#endif                          /* __linux__ */
