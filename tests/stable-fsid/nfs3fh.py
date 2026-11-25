#!/usr/bin/env python3
"""Minimal NFSv3/MOUNT client over TCP that works with raw file handles, as a client that stored them would.
nfs3fh.py PORT mnt <export>        print the root handle (hex)
nfs3fh.py PORT lookup <fh> <name>  print the child's handle
nfs3fh.py PORT getattr <fh>        print "status fsid fileid"
nfs3fh.py PORT read <fh>           print the NFS status of reading the first bytes"""
import os, socket, struct, sys

def call(port, prog, proc, body):
    # NFS3_AUTH: "sys:<uid>:<gid>[:<gid>,...]" (default sys:0:0) or "none"; empty verifier
    auth = os.environ.get("NFS3_AUTH", "sys:0:0").split(":")
    if auth[0] == "none":
        cred = struct.pack(">II", 0, 0)
    else:
        gids = [int(g) for g in auth[3].split(",")] if len(auth) > 3 else []
        c = struct.pack(">IIIII", 0, 0, int(auth[1]), int(auth[2]), len(gids)) + b"".join(struct.pack(">I", g) for g in gids)
        cred = struct.pack(">II", 1, len(c)) + c
    msg = struct.pack(">IIIIII", 1, 0, 2, prog, 3, proc) + cred + struct.pack(">II", 0, 0) + body
    with socket.create_connection(("127.0.0.1", port), timeout=20) as s:
        s.sendall(struct.pack(">I", 0x80000000 | len(msg)) + msg)
        data = b""
        while True:
            hdr = s.recv(4, socket.MSG_WAITALL)
            n = struct.unpack(">I", hdr)[0]
            data += s.recv(n & 0x7fffffff, socket.MSG_WAITALL)
            if n & 0x80000000:
                break
    vlen = struct.unpack(">I", data[16:20])[0]
    off = 20 + ((vlen + 3) & ~3)
    if struct.unpack(">I", data[off:off + 4])[0] != 0:
        sys.exit("rpc call not accepted")
    return data[off + 4:]

def opaque(b):
    return struct.pack(">I", len(b)) + b + b"\0" * (-len(b) % 4)

port, op = int(sys.argv[1]), sys.argv[2]
if op in ("mnt", "lookup"):
    if op == "mnt":
        r = call(port, 100005, 1, opaque(sys.argv[3].encode()))
    else:
        r = call(port, 100003, 3, opaque(bytes.fromhex(sys.argv[3])) + opaque(sys.argv[4].encode()))
    st, n = struct.unpack(">II", r[:8]) if len(r) >= 8 else (struct.unpack(">I", r[:4])[0], 0)
    if st:
        sys.exit(f"status {st}")
    print(r[8:8 + n].hex())
elif op == "read":
    r = call(port, 100003, 6, opaque(bytes.fromhex(sys.argv[3])) + struct.pack(">QI", 0, 64))
    print(struct.unpack(">I", r[:4])[0])
else:
    r = call(port, 100003, 1, opaque(bytes.fromhex(sys.argv[3])))
    st = struct.unpack(">I", r[:4])[0]
    if st:
        print(st, 0, 0)
    else:                       # fattr3: type mode nlink uid gid size used rdev fsid fileid
        fsid, fileid = struct.unpack(">QQ", r[4 + 44:4 + 60])
        print(0, fsid, fileid)
