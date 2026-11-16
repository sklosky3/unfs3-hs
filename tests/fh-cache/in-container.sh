#!/bin/bash
# File handle cache test (-H, -L, duplicate CIFS mount warning). Runs inside
# a privileged Rocky Linux 9 container with the source tree mounted
# read-only at /src (see run.sh).
#
# Pattern under test: a client lists a whole tree, then reads every file by
# the handle it got from the listing, in a different order (what backup,
# migration and assimilation tools do). With the default 4096-entry cache
# most handles miss and unfsd falls back to a tree walk; with a large cache
# and -L they should hit.
set -u
# unfsd runs in its own mount namespace (unshare), created before the test
# mounts its NFS client. Otherwise unfsd can see its own NFS mount: a cache
# miss walks the tree from "/", the walk can descend into that mount (its
# root reports the re-exported directory's inode), and the single-threaded
# server then waits on itself until the soft mount times out.
NDIRS=${NDIRS:-60}
NFILES=${NFILES:-100}           # per directory
fail=0
check() { # description condition-result(0/1) detail
    if [ "$2" = 0 ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 ($3)"; fail=1; fi
}

dnf -q -y --enablerepo=crb install samba cifs-utils nfs-utils gcc make autoconf automake \
    libtool flex bison libtirpc-devel rpcbind procps-ng >/dev/null 2>&1 \
    || { echo "dnf install failed"; exit 2; }

cp -r /src /build && cd /build
cp /usr/share/automake-*/{install-sh,config.sub,config.guess} . 2>/dev/null
(./bootstrap || autoreconf -i) >/dev/null 2>&1
./configure >/dev/null && make -j"$(nproc)" >/dev/null 2>&1 || { echo "build failed"; exit 2; }

# Samba share: NDIRS x NFILES files; each file contains its own relative path
for d in $(seq -w 1 "$NDIRS"); do
    mkdir -p "/srv/share/d$d"
    for f in $(seq -w 1 "$NFILES"); do printf '%s' "d$d/f$f" > "/srv/share/d$d/f$f"; done
done
total=$((NDIRS * NFILES))
useradd -M smbu
(echo pw; echo pw) | smbpasswd -s -a smbu >/dev/null
chown -R smbu /srv/share
cat > /etc/samba/smb.conf <<EOF
[global]
 security = user
 map to guest = never
 server min protocol = SMB2
[share]
 path = /srv/share
 read only = no
 valid users = smbu
EOF
smbd -D; sleep 2
OPTS=username=smbu,password=pw,vers=3.1.1,serverino,actimeo=1,ro
mkdir -p /mnt/cifs /mnt/nfs
mount -t cifs //127.0.0.1/share /mnt/cifs -o $OPTS || { echo "CIFS mount failed"; exit 2; }
rpcbind; sleep 1
echo "/mnt/cifs (ro,no_root_squash)" > /etc/exports.unfsd

stats() { # print "access hit miss" from the SIGUSR1 log line
    kill -USR1 "$(pgrep -x unfsd)"; sleep 1
    grep "fh entries" "$LOG" | tail -1 | awk '{for(i=1;i<=NF;i++){if($i=="access")a=$(i+1);if($i=="hit")h=$(i+1);if($i=="miss")m=$(i+1)}} END{print a+0, h+0, m+0}'
}

# Never leave an NFS mount attached while its server restarts (see
# tests/cifs-nlink): unmount first, and use soft mounts.
NFSOPTS=vers=3,proto=tcp,mountproto=tcp,ro,nolock,soft,timeo=50,retrans=2
nfs_umount() { mountpoint -q /mnt/nfs && { timeout 30 umount /mnt/nfs || umount -l /mnt/nfs; }; return 0; }
stop_unfsd() { nfs_umount; pkill -x unfsd; for i in 1 2 3 4 5; do pgrep -x unfsd >/dev/null || break; sleep 1; done; }

run_case() { # name unfsd-options...
    local name=$1; shift
    stop_unfsd
    LOG=/tmp/unfsd.$name.log
    unshare --mount --propagation private ./unfsd -e /etc/exports.unfsd -t -d "$@" > "$LOG" 2>&1 &
    sleep 2
    timeout 60 mount -t nfs -o $NFSOPTS 127.0.0.1:/mnt/cifs /mnt/nfs \
        || { echo "NFS mount failed ($name)"; tail -20 "$LOG"; fail=1; return; }
    find /mnt/nfs -type f | sort > /tmp/list.txt                       # list + lookup
    shuf --random-source=<(yes) /tmp/list.txt > /tmp/shuf.txt         # deterministic shuffle
    read -r a0 h0 m0 < <(stats)
    local t0=$(date +%s.%N) bad=0 n=0 f c
    while IFS= read -r f; do                                          # read by cached handle
        c=$(<"$f") || { bad=$((bad+1)); continue; }
        [ "$c" = "${f#/mnt/nfs/}" ] || bad=$((bad+1))
        n=$((n+1))
    done < /tmp/shuf.txt
    local t1=$(date +%s.%N)
    read -r a1 h1 m1 < <(stats)
    R_FILES=$(wc -l < /tmp/list.txt); R_BAD=$bad; R_MISS=$((m1 - m0)); R_ACC=$((a1 - a0))
    R_SECS=$(echo "$t1 - $t0" | bc 2>/dev/null || awk "BEGIN{print $t1-$t0}")
    echo "      $name: files=$R_FILES read=$n bad=$bad read-pass accesses=$R_ACC misses=$R_MISS time=${R_SECS}s"
}

run_case default
check "default cache: all files listed" $([ "$R_FILES" = "$total" ]; echo $?) "$R_FILES/$total"
check "default cache: content correct" $([ "$R_BAD" = 0 ]; echo $?) "$R_BAD bad"
check "default cache: read pass misses (test exercises misses)" $([ "$R_MISS" -gt $((total / 4)) ]; echo $?) "$R_MISS misses"
D_MISS=$R_MISS

run_case large -H 100000 -L
check "-H 100000 -L: content correct" $([ "$R_BAD" = 0 ]; echo $?) "$R_BAD bad"
check "-H 100000 -L: read pass almost all hits" $([ "$R_MISS" -lt $((total / 100 + 10)) ]; echo $?) "$R_MISS misses, default had $D_MISS"

run_case tiny -H 16 -L
check "-H 16 (eviction stress): content correct" $([ "$R_BAD" = 0 ]; echo $?) "$R_BAD bad"
check "-H 16: unfsd still running" $(pgrep -x unfsd >/dev/null; echo $?) "pid $(pgrep -x unfsd)"

# duplicate CIFS mount warning
mkdir -p /mnt/cifs2
mount -t cifs //127.0.0.1/share /mnt/cifs2 -o $OPTS || { echo "second CIFS mount failed"; exit 2; }
stop_unfsd
unshare --mount --propagation private ./unfsd -e /etc/exports.unfsd -t -d > /tmp/unfsd.dup.log 2>&1 &
sleep 2
check "duplicate CIFS mount warning logged" $(grep -q "mounted more than once" /tmp/unfsd.dup.log; echo $?) "$(grep -o 'CIFS share [^ ]* is mounted more than once' /tmp/unfsd.dup.log | head -1)"
umount /mnt/cifs2
stop_unfsd
unshare --mount --propagation private ./unfsd -e /etc/exports.unfsd -t -d > /tmp/unfsd.single.log 2>&1 &
sleep 2
check "no warning with one mount per share" $(! grep -q "mounted more than once" /tmp/unfsd.single.log; echo $?) "single mount"

stop_unfsd
[ $fail = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $fail
