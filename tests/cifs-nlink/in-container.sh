#!/bin/bash
# Hard-link count test for unfsd -N. Runs inside a privileged Rocky Linux 9
# container with the source tree mounted read-only at /src (see run.sh).
#
# Builds unfsd, serves a Samba share on loopback, mounts it with the kernel
# CIFS client, re-exports the CIFS mount with unfsd and checks link counts
# through the kernel NFS client:
#   -N never          link count 1 on every name (reproduces the CIFS behaviour)
#   -N auto / always  link count 3 on all three names of one file
#   local export      native link counts, no statx calls added in auto mode
set -u
fail=0
check() { # description expected actual
    if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fail=1; fi
}

dnf -q -y --enablerepo=crb install samba cifs-utils nfs-utils gcc make autoconf automake \
    libtool flex bison libtirpc-devel rpcbind procps-ng strace >/dev/null 2>&1 \
    || { echo "dnf install failed"; exit 2; }

cp -r /src /build && cd /build
cp /usr/share/automake-*/{install-sh,config.sub,config.guess} . 2>/dev/null
(./bootstrap || autoreconf -i) >/dev/null 2>&1
./configure >/dev/null && make -j"$(nproc)" >/dev/null 2>&1 || { echo "build failed"; exit 2; }

# Samba share with one file under three names, in two directories
mkdir -p /srv/share/a /srv/share/b
echo hello > /srv/share/a/data.dat
ln /srv/share/a/data.dat /srv/share/a/link-same.dat
ln /srv/share/a/data.dat /srv/share/b/link-other.dat
echo solo > /srv/share/a/solo.dat
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

mkdir -p /mnt/cifs /mnt/nfs
mount -t cifs //127.0.0.1/share /mnt/cifs \
    -o username=smbu,password=pw,vers=3.1.1,serverino,actimeo=1,ro \
    || { echo "CIFS mount failed (does the kernel have the cifs module?)"; exit 2; }
rpcbind; sleep 1

# Never leave an NFS mount attached while its server restarts: a mount whose
# server is gone can block umount. Unmount first, and use soft mounts.
NFSOPTS=vers=3,proto=tcp,mountproto=tcp,ro,nolock,soft,timeo=50,retrans=2
nfs_umount() { for m in "$@"; do mountpoint -q "$m" && { timeout 30 umount "$m" || umount -l "$m"; }; done; return 0; }
start_unfsd() { # mode exports
    nfs_umount /mnt/nfs /mnt/nfs2
    pkill -x unfsd; for i in 1 2 3 4 5; do pgrep -x unfsd >/dev/null || break; sleep 1; done
    echo "$2" > /etc/exports.unfsd
    ./unfsd -e /etc/exports.unfsd -t -N "$1" -d > "/tmp/unfsd.$1.log" 2>&1 &
    sleep 2
}
links() { stat -c %h "$@" | tr '\n' ' ' | sed 's/ $//'; }

for mode in never auto always; do
    start_unfsd $mode "/mnt/cifs (ro,no_root_squash)"
    timeout 60 mount -t nfs -o $NFSOPTS,noac,lookupcache=none \
        127.0.0.1:/mnt/cifs /mnt/nfs || { echo "NFS mount failed ($mode)"; tail -20 /tmp/unfsd.$mode.log; exit 2; }
    echo 3 > /proc/sys/vm/drop_caches
    ls -f /mnt/cifs/a /mnt/cifs/b > /dev/null      # CIFS learns the names from a listing
    got=$(links /mnt/nfs/a/data.dat /mnt/nfs/a/link-same.dat /mnt/nfs/b/link-other.dat)
    if [ $mode = never ]; then want="1 1 1"; else want="3 3 3"; fi
    check "-N $mode: hard-linked names" "$want" "$got"
    check "-N $mode: single-name file" "1" "$(links /mnt/nfs/a/solo.dat)"
    ino=$(stat -c %i /mnt/nfs/a/data.dat /mnt/nfs/a/link-same.dat /mnt/nfs/b/link-other.dat | sort -u | wc -l)
    check "-N $mode: one inode for all names" "1" "$ino"
done
nfs_umount /mnt/nfs

# A non-CIFS export: native counts, and auto mode must not call statx
mkdir -p /srv/local && echo x > /srv/local/f && ln /srv/local/f /srv/local/g
start_unfsd auto "/srv/local (ro,no_root_squash)"
mkdir -p /mnt/nfs2
timeout 60 mount -t nfs -o $NFSOPTS,noac 127.0.0.1:/srv/local /mnt/nfs2 \
    || { echo "NFS mount of local export failed"; tail -20 /tmp/unfsd.auto.log; exit 2; }
strace -f -e trace=statx -p "$(pgrep -x unfsd)" -o /tmp/statx.trace & sp=$!
sleep 1; stat /mnt/nfs2/f /mnt/nfs2/g > /dev/null; sleep 1; kill $sp 2>/dev/null; wait $sp 2>/dev/null
check "local export: native link counts" "2 2" "$(links /mnt/nfs2/f /mnt/nfs2/g)"
check "local export: no statx calls in auto mode" "0" "$(grep -c 'statx(' /tmp/statx.trace)"

nfs_umount /mnt/nfs2
[ $fail = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $fail
