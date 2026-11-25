#!/bin/bash
# AUTH_NONE request test. Runs inside a Rocky Linux 9 container with the source tree mounted read-only at /src.
# A request without a Unix credential must not crash unfsd, must run as the anonymous user, and must not inherit
# the supplementary groups of the request before it.
set -u
fail=0
check() { # description condition-result(0/1) detail
    if [ "$2" = 0 ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 ($3)"; fail=1; fi
}
dnf -q -y --enablerepo=crb install gcc make autoconf automake libtool flex bison libtirpc-devel procps-ng python3 \
    >/dev/null 2>&1 || { echo "dnf install failed"; exit 2; }
cp -r /src /build && cd /build
cp /usr/share/automake-*/{install-sh,config.sub,config.guess} . 2>/dev/null
(./bootstrap || autoreconf -i) >/dev/null 2>&1
./configure >/dev/null && make -j"$(nproc)" >/dev/null 2>&1 || { echo "build failed"; exit 2; }

mkdir -p /srv/x; echo open > /srv/x/world; echo secret > /srv/x/group; chmod 755 /srv/x; chmod 644 /srv/x/world
chown root:1234 /srv/x/group; chmod 640 /srv/x/group
echo "/srv/x (ro,insecure)" > /etc/exports.unfsd
PORT=12049
./unfsd -e /etc/exports.unfsd -t -p -n $PORT -m $PORT -d > /tmp/unfsd.log 2>&1 &
sleep 1
nfs() { NFS3_AUTH=$1 timeout 30 python3 /build/tests/stable-fsid/nfs3fh.py $PORT "${@:2}" 2>/dev/null; }
alive() { pgrep -x unfsd >/dev/null; }
root=$(nfs sys:0:0 mnt /srv/x); w=$(nfs sys:1000:1000 lookup $root world); g=$(nfs sys:1000:1000 lookup $root group)
[ -n "$w" ] && [ -n "$g" ]; check "setup: handles obtained" $? "${root:0:16}"

r=$(nfs sys:1000:1000:1234 read $g); [ "$r" = 0 ]; check "member of the group reads the file" $? "status $r"
r=$(nfs none read $g); alive; check "AUTH_NONE read does not crash unfsd" $? "status ${r:-no reply}"
[ "$r" = 13 ]; check "AUTH_NONE does not inherit the previous groups" $? "status $r"
r=$(nfs none read $w); [ "$r" = 0 ]; check "AUTH_NONE reads a world-readable file" $? "status $r"
r=$(nfs none getattr $root); [ "${r%% *}" = 0 ]; check "AUTH_NONE getattr works" $? "${r%% *}"
r=$(nfs none lookup $root world); [ "$r" = "$w" ]; check "AUTH_NONE lookup works" $? "${r:0:16}"
r=$(nfs sys:1000:1000:1234 read $g); [ "$r" = 0 ] && alive; check "normal requests still work afterwards" $? "status $r"
[ $fail = 0 ] && echo "ALL PASSED" || { echo "SOME TESTS FAILED"; tail -5 /tmp/unfsd.log; }
exit $fail
