
/*
 * UNFS3 filehandle cache
 * (C) 2004
 * see file LICENSE for license details
 */

#include "config.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <rpc/rpc.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <syslog.h>

#include "nfs.h"
#include "fh.h"
#include "locate.h"
#include "fh_cache.h"
#include "mount.h"
#include "daemon.h"
#include "attr.h"
#include "Config/exports.h"
#include "backend.h"

/*
 * The cache maps <dev,ino> to a path. A miss is expensive: fh_decomp_raw()
 * walks the tree from "/" (see fh_rec() in fh.c), so the cache should hold
 * the working set of the client. Entries live in a hash table (lookup) and
 * on an LRU list (eviction); paths are stored at their real length.
 *
 * Size: opt_fh_cache_size entries (-H, default 4096 as in earlier versions).
 * With -L, every name returned by READDIR/READDIRPLUS is added as well,
 * so a client that lists a tree and later accesses its files by handle
 * (backup, migration and assimilation tools) finds them in the cache.
 */

typedef struct fhc_ent {
    uint32 dev;			/* device */
    uint64 ino;			/* inode */
    char *path;			/* pathname (malloc'd) */
    struct fhc_ent *hnext;	/* hash chain */
    struct fhc_ent *prev;	/* LRU list, towards most recent */
    struct fhc_ent *next;	/* LRU list, towards least recent */
} fhc_ent;

unsigned int opt_fh_cache_size = FH_CACHE_DEFAULT_SIZE;
int opt_fh_cache_learn = FALSE;

static fhc_ent **fhc_hash = NULL;
static unsigned int fhc_buckets = 0;	/* power of two */
static unsigned int fhc_count = 0;
static fhc_ent *lru_head = NULL;	/* most recently used */
static fhc_ent *lru_tail = NULL;	/* least recently used */

/*
 * entry returned by the last lookup or add
 *
 * this entry must not be evicted before the next lookup, because
 * operations such as CREATE may still be needing the path inside the
 * entry for getting directory attributes
 */
static fhc_ent *fhc_pinned = NULL;

/* statistics */
int fh_cache_max = 0;
int fh_cache_use = 0;
int fh_cache_hit = 0;

static unsigned int fhc_bucket(uint32 dev, uint64 ino)
{
    uint64 h = ino ^ (ino >> 29) ^ ((uint64) dev * 0x9E3779B97F4A7C15ULL);

    h ^= h >> 32;
    return (unsigned int) h & (fhc_buckets - 1);
}

/*
 * initialize cache
 */
void fh_cache_init(void)
{
    unsigned int want = opt_fh_cache_size < 16 ? 16 : opt_fh_cache_size;

    fhc_buckets = 16;
    while (fhc_buckets < want && fhc_buckets < (1U << 30))
        fhc_buckets <<= 1;

    fhc_hash = calloc(fhc_buckets, sizeof(fhc_ent *));
    if (!fhc_hash) {
        logmsg(LOG_CRIT, "Unable to allocate file handle cache (%u entries)",
               opt_fh_cache_size);
        daemon_exit(0);
    }
}

static void lru_unlink(fhc_ent * e)
{
    if (e->prev)
        e->prev->next = e->next;
    else
        lru_head = e->next;
    if (e->next)
        e->next->prev = e->prev;
    else
        lru_tail = e->prev;
    e->prev = e->next = NULL;
}

static void lru_push_front(fhc_ent * e)
{
    e->prev = NULL;
    e->next = lru_head;
    if (lru_head)
        lru_head->prev = e;
    lru_head = e;
    if (!lru_tail)
        lru_tail = e;
}

static void lru_touch(fhc_ent * e)
{
    if (e != lru_head) {
        lru_unlink(e);
        lru_push_front(e);
    }
}

/*
 * find entry given device and inode number
 */
static fhc_ent *fhc_find(uint32 dev, uint64 ino)
{
    fhc_ent *e;

    for (e = fhc_hash[fhc_bucket(dev, ino)]; e; e = e->hnext)
        if (e->dev == dev && e->ino == ino)
            return e;
    return NULL;
}

/*
 * remove (free) a cache entry
 */
static void fhc_remove(fhc_ent * e)
{
    fhc_ent **pp = &fhc_hash[fhc_bucket(e->dev, e->ino)];

    while (*pp && *pp != e)
        pp = &(*pp)->hnext;
    if (*pp)
        *pp = e->hnext;
    lru_unlink(e);
    if (fhc_pinned == e)
        fhc_pinned = NULL;
    free(e->path);
    free(e);
    fhc_count--;
}

/*
 * evict the least recently used entry, never the pinned one
 */
static void fhc_evict(void)
{
    fhc_ent *victim = lru_tail;

    if (victim && victim == fhc_pinned)
        victim = victim->prev;
    if (victim)
        fhc_remove(victim);
}

static char *fhc_add(uint32 dev, uint64 ino, const char *path, int pin)
{
    fhc_ent *e;
    char *copy;
    unsigned int b;

    e = fhc_find(dev, ino);
    if (e) {
        /* if we already have a matching entry, update that */
        if (e->path != path && strcmp(e->path, path) != 0) {
            copy = strdup(path);
            if (!copy)
                return NULL;
            free(e->path);
            e->path = copy;
        }
        lru_touch(e);
    } else {
        /* otherwise make room by evicting the least recently used entry */
        while (fhc_count >= opt_fh_cache_size && fhc_count > 1)
            fhc_evict();

        e = malloc(sizeof(fhc_ent));
        copy = strdup(path);
        if (!e || !copy) {
            free(e);
            free(copy);
            return NULL;
        }
        e->dev = dev;
        e->ino = ino;
        e->path = copy;
        b = fhc_bucket(dev, ino);
        e->hnext = fhc_hash[b];
        fhc_hash[b] = e;
        lru_push_front(e);
        fhc_count++;
        if ((int) fhc_count > fh_cache_max)
            fh_cache_max = fhc_count;
    }

    if (pin)
        fhc_pinned = e;
    return e->path;
}

/*
 * add an entry to the filehandle cache
 *
 * returns a pointer to the cached copy of the path, which stays valid
 * until the next cache lookup or add
 */
char *fh_cache_add(uint32 dev, uint64 ino, const char *path)
{
    char *res = fhc_add(dev, ino, path, TRUE);

    /* on allocation failure, fall back to the caller's string */
    return res ? res : (char *) path;
}

/*
 * add an entry learned from a directory listing (-L); does not change
 * which entry is pinned, so the directory being read stays valid
 */
void fh_cache_learn(uint32 dev, uint64 ino, const char *path)
{
    if (opt_fh_cache_learn)
        (void) fhc_add(dev, ino, path, FALSE);
}

/*
 * lookup an entry in the cache given a device and inode number
 */
static char *fh_cache_lookup(uint32 dev, uint64 ino)
{
    int res;
    fhc_ent *e;
    backend_statstruct buf;

    e = fhc_find(dev, ino);
    if (!e)
        return NULL;

    /* check whether path to <dev,ino> relation still holds */
    res = backend_lstat(e->path, &buf);
    if (res == -1 || buf.st_dev != dev || buf.st_ino != ino) {
        /* object does not exist any more, or relation has changed */
        fhc_remove(e);
        return NULL;
    }

    /* cache hit, mark entry as most recently used */
    lru_touch(e);

    /* update stat cache */
    fix_dir_times(e->path, &buf);
    st_cache_valid = TRUE;
    st_cache = buf;

    /* prevent the next fh_cache_add from evicting the entry */
    fhc_pinned = e;

    return e->path;
}

/*
 * update a fh inode cache for an operation like rename
 */
void fh_cache_update(nfs_fh3 fh, char *path)
{
    unfs3_fh_t *obj = (void *) fh.data.data_val;
    backend_statstruct buf;

    if (backend_lstat(path, &buf) != -1) {
        fh_cache_add(obj->dev, buf.st_ino, path);
    }
}
/*
 * resolve a filename into a path
 * cache-using wrapper for fh_decomp_raw
 */
char *fh_decomp(nfs_fh3 fh)
{
    char *result;
    unfs3_fh_t obj = fh_decode(&fh);

    if (!nfh_valid(fh)) {
        st_cache_valid = FALSE;
        return NULL;
    }

    /* Does the fsid match some static fsid? */
    if ((result = export_point_from_fsid(obj.dev)) != NULL) {
        if (obj.ino == 0x1) {
            /* This FH refers to the export point itself */
            /* Need to fill stat cache */
            st_cache_valid = TRUE;

            if (backend_lstat(result, &st_cache) == -1) {
                /* export point does not exist. This probably means that we
                   are using autofs and no media is inserted. Fill stat cache
                   with dummy information */
                st_cache.st_mode = S_IFDIR | S_IRWXU | S_IRWXG | S_IRWXO;
                st_cache.st_nlink = 2;
                st_cache.st_uid = 0;
                st_cache.st_gid = 0;
                st_cache.st_rdev = 0;
                st_cache.st_size = 4096;
                st_cache.st_blksize = 512;
                st_cache.st_blocks = 8;
                st_cache.st_atime = 0;
                st_cache.st_mtime = 0;
                st_cache.st_ctime = 0;
            } else {
                /* Stat was OK, but make sure the values are sane. Supermount
                   returns insane values when no media is inserted, for
                   example. */
                if (st_cache.st_nlink == 0)
                    st_cache.st_nlink = 1;
                if (st_cache.st_size == 0)
                    st_cache.st_size = 4096;
                if (st_cache.st_blksize == 0)
                    st_cache.st_blksize = 512;
                if (st_cache.st_blocks == 0)
                    st_cache.st_blocks = 8;
                fix_dir_times(result, &st_cache);
            }

            st_cache.st_dev = obj.dev;
            st_cache.st_ino = 0x1;
            return result;
        }
    }

    /* try lookup in cache, increase cache usage counter */
    result = fh_cache_lookup(obj.dev, obj.ino);
    fh_cache_use++;

    if (!result) {
        /* not found, resolve the hard way */
        result = fh_decomp_raw(&obj);

        /* if still not found, do full recursive search) */
        if (!result)
            result = backend_locate_file(obj.dev, obj.ino);

        if (result)
            /* add to cache for later use if resolution ok */
            result = fh_cache_add(obj.dev, obj.ino, result);
        else
            /* could not resolve in any way */
            st_cache_valid = FALSE;
    } else
        /* found, update cache hit statistic */
        fh_cache_hit++;

    return result;
}

/*
 * compose a filehandle for a path
 * cache-using wrapper for fh_comp_raw
 * exports_options must be called before
 */
unfs3_fh_t fh_comp(const char *path, struct svc_req * rqstp, int need_dir)
{
    unfs3_fh_t res;

    res = fh_comp_raw(path, rqstp, need_dir);
    if (fh_valid(res))
        /* add to cache for later use */
        fh_cache_add(res.dev, res.ino, path);

    res.pwhash = export_password_hash;
    return res;
}

/*
 * return pointer to composed filehandle
 * wrapper for fh_comp
 */
unfs3_fh_t *fh_comp_ptr(const char *path, struct svc_req * rqstp,
                        int need_dir)
{
    static unfs3_fh_t res;

    res = fh_comp(path, rqstp, need_dir);
    if (fh_valid(res))
        return &res;
    else
        return NULL;
}
