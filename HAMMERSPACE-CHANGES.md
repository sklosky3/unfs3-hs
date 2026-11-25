# Changes in this fork

This is a fork of [unfs3/unfs3](https://github.com/unfs3/unfs3), based on
upstream commit `1c0d6f4` (after the 0.11.0 release). It is maintained for
one use case: re-exporting a Linux CIFS (SMB) mount over NFSv3 so that
migration and assimilation tools can read an SMB-only file server through
NFS. Upstream's license and copyright notices are unchanged.

The changes are kept as separate commits on top of upstream so that they
can be rebased onto new upstream releases and offered upstream.

## 1. Minimal READDIRPLUS

Upstream answers READDIRPLUS with `NFS3ERR_NOTSUPP`, by design. Some
clients issue READDIRPLUS and cannot fall back to READDIR.

- Returns names, fileids and cookies, using the same directory reader as
  READDIR.
- Returns **no per-entry attributes and no file handles**. Both are
  optional in RFC 1813; clients follow up with LOOKUP. This keeps
  upstream's reasoning that attributes and handles cannot be fetched
  atomically from user space.
- Limits: at most 143 entries per reply; reply size is derived from
  `dircount`/`maxcount`.
- Planned: make it opt-in, size the reply from the request instead of a
  fixed array, and run an NFSv3 conformance suite against it.

## 2. Hard link counts on CIFS exports (`-N`)

The Linux CIFS client builds inodes from SMB directory listings, which
carry no link count, and caches a link count of 1 until its attribute
cache expires (`actimeo`, 1 s by default). A client that looks up names
right after listing a directory then sees each name of a hard-linked file
as a separate file.

- For a regular file whose `lstat` reports one link, LOOKUP and GETATTR
  ask the kernel for a fresh count with
  `statx(AT_STATX_FORCE_SYNC, STATX_NLINK)`, which costs one SMB query.
- Listings, reads, directories and symlinks are unchanged.
- `-N auto` (default): only on CIFS/SMB3 filesystems (`statfs` magic
  `0xFF534D42` / `0xFE534D42`, cached per device). `-N always`: any
  filesystem. `-N never`: upstream behaviour.
- Linux only; compiles to a no-op elsewhere.
- Test: `tests/cifs-nlink/run.sh`.

An alternative that needs no code change is mounting the CIFS share with
`actimeo=0`, at a much higher cost: every attribute lookup becomes an SMB
round trip.

## 3. File handle cache (`-H`, `-L`) and duplicate-mount warning

NFS clients address files by handle. unfsd maps handles to paths with a
cache; a handle that is not cached is resolved by walking the tree from
`/`, matching a one-byte inode hash per level (`fh_rec` in `fh.c`). Over
a CIFS mount each step of that walk can be an SMB round trip.

Upstream's cache is a fixed array of 4,096 entries, searched linearly,
with a 4 KB path buffer per entry. A client that lists a large tree and
then reads its files by handle in a different order (backup, migration
and assimilation tools) misses on most files.

- The cache is now a hash table with an LRU list: one-step lookup and
  eviction. Paths are stored at their real length (about 64 bytes plus
  the path per entry).
- `-H <entries>`: cache size. Default 4096, as upstream.
- `-L`: also cache every name returned by READDIR/READDIRPLUS. Use with a
  large `-H`.
- At startup and on SIGHUP, unfsd logs a warning when one CIFS/SMB3 share
  is mounted more than once (same `//server/share` in `/proc/self/mounts`).
- `SIGUSR1` logs cache statistics (entries, accesses, hits, misses), as
  before.
- Test: `tests/fh-cache/run.sh`. On 6,000 files read back in shuffled order
  after a listing: default cache 4,186 misses; `-H 100000 -L` 0 misses;
  `-H 16 -L` (eviction stress) all content correct.

Measured with a real Windows Server SMB share (about 20,000 files, 265
directories) re-exported to an NFS assimilation client that lists the tree
and then reads every file by handle: default cache 2m 12s with 50% handle
misses; `-H 1000000 -L` 50 s with no misses. One run each on a small lab
tree, not a benchmark.

Sizing: one entry per file the client works on at a time. 1,000,000
entries take roughly 130 MB with typical path lengths.

## 4. Stable filesystem IDs (`-S`)

Linux only. unfsd puts the device number (`st_dev`) of the exported
filesystem into every file handle and reports it as the NFS `fsid`. A CIFS
mount gets an anonymous device number when it is mounted, so the number
depends on mount order. After a gateway reboot it can differ, every stored
file handle becomes stale, and a client such as Hammerspace marks the volume
unavailable ("wrong root filehandle"). Seen in an OCI test on 2026-11-25.

- `-S auto`: for every CIFS/SMB3 mount, use an ID hashed from the server
  path (lower-cased) and the mounted subtree instead of the device number.
- `-S /mountpoint=<id>`: set the ID for one mounted filesystem (any type);
  may be repeated, and wins over `auto`.

The mapping is applied to every `stat` result, so handles, caches, path
resolution and attributes agree, and it follows remounts while unfsd runs.
The log shows each mount's ID.

Notes:

- Turning `-S` on changes the file handles once. Enable it before clients
  store handles (for Hammerspace: before the volume is added).
- `auto` depends on the server path as mounted. Mounting the same share by IP
  address on one boot and by name on another gives a different ID. Gateways
  that mount the same path get the same ID; whether that is enough to fail
  over between gateways has not been tested.
- If two mounts would get the same ID, the second keeps its device number
  and unfsd logs it.

Test: `tests/stable-fsid/run.sh` (mounts two shares in a different order
between restarts and resolves handles stored before the restart).

## Recommended proxy setup

```
mount -t cifs //server/share /export/share \
    -o ro,vers=3.1.1,serverino,backupuid=0,backupgid=0,credentials=/etc/unfsd/share.cred
unfsd -t -N auto -H 1000000 -L -S auto -e /etc/exports.unfsd
```

- `serverino` is required: it makes the NFS fileid equal the SMB file ID.
- `backupuid=0,backupgid=0` lets the proxy read files whose ACLs exclude
  the mounting account (backup intent).
- **Do not mount the proxy's own NFS exports on the proxy.** A cache
  miss walks the tree from `/`; if the walk reaches such a mount,
  single-threaded unfsd ends up waiting on itself.
- **Mount each share only once on the proxy.** Identical CIFS mounts of
  one share share a superblock, so they have the same device and inode
  numbers. unfsd resolves file handles that are not in its cache by
  walking from `/` and matching inode hashes, and duplicate trees make
  that walk explore every copy (and it can resolve to a path in the wrong
  mount).

## Known limitations

- unfsd is single-threaded; every NFS call waits on a CIFS round trip.
- A cache miss is still resolved by a tree walk from `/`. On trees much
  larger than the cache, misses stay expensive; a handle format that
  records the parent directory would fix that and is under consideration.
- NFSv3 only, no lock manager (clients mount with `nolock`).
- Names that are valid on the SMB server but not addressable over SMB
  from Linux, symlinks and alternate data streams are outside what a CIFS
  re-export can provide.
