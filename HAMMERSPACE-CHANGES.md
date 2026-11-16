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

## Recommended proxy setup

```
mount -t cifs //server/share /export/share \
    -o ro,vers=3.1.1,serverino,backupuid=0,backupgid=0,credentials=/etc/unfsd/share.cred
unfsd -t -N auto -e /etc/exports.unfsd
```

- `serverino` is required: it makes the NFS fileid equal the SMB file ID.
- `backupuid=0,backupgid=0` lets the proxy read files whose ACLs exclude
  the mounting account (backup intent).
- **Mount each share only once on the proxy.** Identical CIFS mounts of
  one share share a superblock, so they have the same device and inode
  numbers. unfsd resolves file handles that are not in its cache by
  walking from `/` and matching inode hashes, and duplicate trees make
  that walk explore every copy (and it can resolve to a path in the wrong
  mount).

## Known limitations

- unfsd is single-threaded; every NFS call waits on a CIFS round trip.
- The file-handle cache holds 4,096 entries (`fh_cache.c`). Misses are
  resolved by a tree walk from `/` (`fh_rec` in `fh.c`), which is slow on
  large trees. A larger or configurable cache is planned.
- NFSv3 only, no lock manager (clients mount with `nolock`).
- Names that are valid on the SMB server but not addressable over SMB
  from Linux, symlinks and alternate data streams are outside what a CIFS
  re-export can provide.
