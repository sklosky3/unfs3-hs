#!/bin/bash
# Stable filesystem ID test (-S). Runs inside a privileged Rocky Linux 9 container with the source tree
# mounted read-only at /src (see run.sh).
#
# Pattern under test: a client stores file handles; the gateway restarts and its CIFS shares come up with
# different device numbers (mounted in another order). The stored handles must still resolve.
set -u
fail=0
check() { # description condition-result(0/1) detail
    if [ "$2" = 0 ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 ($3)"; fail=1; fi
}
dnf -q -y --enablerepo=crb install samba cifs-utils gcc make autoconf automake libtool flex bison \
    libtirpc-devel procps-ng python3 util-linux >/dev/null 2>&1 || { echo "dnf install failed"; exit 2; }
cp -r /src /build && cd /build
cp /usr/share/automake-*/{install-sh,config.sub,config.guess} . 2>/dev/null
(./bootstrap || autoreconf -i) >/dev/null 2>&1
./configure >/dev/null && make -j"$(nproc)" 2>/tmp/make.log >/dev/null || { echo "build failed"; tail -30 /tmp/make.log; exit 2; }
grep -A3 'stable_fsid' /tmp/make.log

for s in a b; do mkdir -p /srv/$s/dir/sub; echo "file-$s" > /srv/$s/dir/sub/f; done
useradd -M smbu; (echo pw; echo pw) | smbpasswd -s -a smbu >/dev/null; chown -R smbu /srv/a /srv/b
cat > /etc/samba/smb.conf <<C
[global]
 security = user
 server min protocol = SMB2
[sharea]
 path = /srv/a
 valid users = smbu
[shareb]
 path = /srv/b
 valid users = smbu
C
smbd -D; sleep 2
OPTS=username=smbu,password=pw,vers=3.1.1,serverino,ro
mkdir -p /mnt/a /mnt/b /mnt/pad1 /mnt/pad2 /mnt/pad3
printf '/mnt/a (ro,no_root_squash,insecure)\n/mnt/b (ro,no_root_squash,insecure)\n' > /etc/exports.unfsd
PORT=12049; NFS="python3 /build/tests/stable-fsid/nfs3fh.py $PORT"
mnt() { mount -t cifs //127.0.0.1/share$1 ${2:-/mnt/$1} -o $OPTS || { echo "CIFS mount $1 failed"; exit 2; }; }
mount_order() { # "ab" = a first; "ba" = b first after extra mounts that shift the device numbers
    umount /mnt/a /mnt/b /mnt/pad1 /mnt/pad2 /mnt/pad3 2>/dev/null
    if [ "$1" = ab ]; then mnt a; mnt b
    else for p in 1 2 3; do mount -t tmpfs pad /mnt/pad$p; done; mnt b; mnt a; fi
}
start() { ./unfsd -e /etc/exports.unfsd -t -p -n $PORT -m $PORT -d "$@" >/tmp/unfsd.log 2>&1 & sleep 1; pgrep -x unfsd >/dev/null || { cat /tmp/unfsd.log; exit 2; }; }
stop() { pkill -x unfsd; for i in 1 2 3 4 5; do pgrep -x unfsd >/dev/null || break; sleep 1; done; }
handles() { # export -> "root-handle file-handle"
    local r d s f; r=$($NFS mnt $1) && d=$($NFS lookup $r dir) && s=$($NFS lookup $d sub) && f=$($NFS lookup $s f) && echo "$r $f"; }
devs() { echo "a=$(stat -c %d /mnt/a) b=$(stat -c %d /mnt/b)"; }

run_case() { # name expect-stable(1/0) unfsd-options...
    local name=$1 stable=$2; shift 2
    mount_order ab; start "$@"; local d1=$(devs) A1=$(handles /mnt/a) B1=$(handles /mnt/b); local g1=$($NFS getattr ${A1#* }); stop
    mount_order ba; start "$@"; local d2=$(devs)
    local old=$($NFS getattr ${A1#* }) oldb=$($NFS getattr ${B1#* })    # stored handles, first thing after restart
    local A2=$(handles /mnt/a) B2=$(handles /mnt/b); stop
    echo "--- $name: devices $d1 then $d2"
    [ "$d1" != "$d2" ]; check "$name: device numbers changed" $? "$d1 / $d2"
    if [ $stable = 1 ]; then
        [ -n "$A1" ] && [ "$A1" = "$A2" ] && [ "$B1" = "$B2" ]; check "$name: handles identical after remount" $? "${A1%% *}"
        [ "$old" = "$g1" ] && [ "${old%% *}" = 0 ] && [ "${oldb%% *}" = 0 ]; check "$name: stored handles resolve, same fsid and fileid" $? "$old"
        [ "${A1%% *}" != "${B1%% *}" ] && [ "$(echo $old | cut -d' ' -f2)" != "$(echo $oldb | cut -d' ' -f2)" ]; check "$name: the two exports have different IDs" $? "$(echo $old | cut -d' ' -f2) $(echo $oldb | cut -d' ' -f2)"
    else
        [ "$A1" != "$A2" ] && [ "${old%% *}" != 0 ]; check "$name: handles change and stored handle fails (the defect)" $? "status ${old%% *}"
    fi
}
run_case without-S 0
run_case auto 1 -S auto
grep 'stable fsid' /tmp/unfsd.log | head -3
run_case manual 1 -S /mnt/a=101 -S /mnt/b/=102
mount_order ab; start -S /mnt/a=7 -S auto; r=$($NFS mnt /mnt/a); got=$($NFS getattr $r); stop
[ "$(echo $got | cut -d' ' -f2)" = $((0x40000007)) ]; check "manual ID wins over auto" $? "$got"

# remount while unfsd is running: the table follows the mount table
mount_order ab; start -S auto; before=$(handles /mnt/a); mount_order ba; sleep 1; after=$(handles /mnt/a); got=$($NFS getattr ${before#* }); stop
[ -n "$before" ] && [ "$before" = "$after" ] && [ "${got%% *}" = 0 ]; check "remount under a running unfsd keeps handles" $? "$got"

# same share on another server name case gives the same ID
mount_order ab; start -S auto; h1=$(handles /mnt/a); stop; umount /mnt/a; mount -t cifs //127.0.0.1/SHAREA /mnt/a -o $OPTS; start -S auto; h2=$(handles /mnt/a); stop
[ "${h1%% *}" = "${h2%% *}" ]; check "share name case does not change the ID" $? "${h1%% *} ${h2%% *}"

./unfsd -S nonsense >/dev/null 2>&1; [ $? = 1 ]; check "bad -S argument rejected" $? "exit 1"
[ $fail = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $fail
