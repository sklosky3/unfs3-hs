#!/usr/bin/env python3
"""handles.py PORT collect <export> <out>   store every file handle with its fileid (a client that saw the tree)
handles.py PORT check <stored>            getattr every stored handle in a shuffled order; print "total bad" """
import os, random, struct, sys

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "..", "stable-fsid", "nfs3fh.py")).read()
exec(src.split("port, op = ")[0])          # call() and opaque() from the raw-handle client

port, op = int(sys.argv[1]), sys.argv[2]

def lookup(fh, name):
    r = call(port, 100003, 3, opaque(fh) + opaque(name.encode()))
    st = struct.unpack(">I", r[:4])[0]
    if st:
        sys.exit(f"lookup {name}: status {st}")
    n = struct.unpack(">I", r[4:8])[0]
    return r[8:8 + n]

def getattr_(fh):
    r = call(port, 100003, 1, opaque(fh))
    st = struct.unpack(">I", r[:4])[0]
    return (st, 0) if st else (0, struct.unpack(">Q", r[4 + 52:4 + 60])[0])

if op == "collect":
    root, out = sys.argv[3], sys.argv[4]
    r = call(port, 100005, 1, opaque(root.encode()))
    n = struct.unpack(">I", r[4:8])[0]
    top = r[8:8 + n]
    with open(out, "w") as o:
        for d in sorted(os.listdir(root)):
            dfh = lookup(top, d)
            for f in sorted(os.listdir(os.path.join(root, d))):
                fh = lookup(dfh, f)
                st, fileid = getattr_(fh)
                if st:
                    sys.exit(f"getattr {d}/{f}: status {st}")
                o.write(f"{fh.hex()} {fileid} {d}/{f}\n")
else:
    rows = [l.split(" ", 2) for l in open(sys.argv[3])]
    random.Random(1).shuffle(rows)
    bad = 0
    for fh, fileid, name in rows:
        if getattr_(bytes.fromhex(fh)) != (0, int(fileid)):
            bad += 1
    print(len(rows), bad)
