#!/bin/bash
# Handle-miss walk test. Runs inside a privileged Rocky Linux 9 container with
# the source tree mounted read-only at /src (see run.sh).
#
# Pattern under test: a client stores a handle for every file, unfsd restarts
# (empty cache), and the client then uses the stored handles in random order.
# That is what an assimilation's file access test does after a gateway restart.
# Without learning during the walk, every file costs its own walk of the
# directory; with -L one walk per directory should serve all its files.
set -u
NDIRS=${NDIRS:-20}
NFILES=${NFILES:-200}
fail=0
check() { # description condition-result(0/1) detail
    if [ "$2" = 0 ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 ($3)"; fail=1; fi
}
dnf -q -y --enablerepo=crb install samba cifs-utils gcc make autoconf automake libtool flex bison \
    libtirpc-devel procps-ng python3 strace >/dev/null 2>&1 || { echo "dnf install failed"; exit 2; }
cp -r /src /build && cd /build
cp /usr/share/automake-*/{install-sh,config.sub,config.guess} . 2>/dev/null
(./bootstrap || autoreconf -i) >/dev/null 2>&1
./configure >/dev/null && make -j"$(nproc)" >/dev/null 2>&1 || { echo "build failed"; exit 2; }

for d in $(seq -w 1 "$NDIRS"); do
    mkdir -p "/srv/share/d$d"
    for f in $(seq -w 1 "$NFILES"); do printf '%s' "d$d/f$f" > "/srv/share/d$d/f$f"; done
done
# two names for one file in one directory (hard link)
ln /srv/share/d01/f001 /srv/share/d01/hardlink
total=$((NDIRS * NFILES + 1))
useradd -M smbu; (echo pw; echo pw) | smbpasswd -s -a smbu >/dev/null; chown -R smbu /srv/share
cat > /etc/samba/smb.conf <<C
[global]
 security = user
 server min protocol = SMB2
[share]
 path = /srv/share
 valid users = smbu
C
smbd -D; sleep 2
mkdir -p /mnt/cifs
mount -t cifs //127.0.0.1/share /mnt/cifs -o username=smbu,password=pw,vers=3.1.1,serverino,ro || { echo "CIFS mount failed"; exit 2; }
echo "/mnt/cifs (ro,no_root_squash,insecure)" > /etc/exports.unfsd
PORT=12049
H="python3 /build/tests/miss-walk/handles.py $PORT"
start() { ./unfsd -e /etc/exports.unfsd -t -p -n $PORT -m $PORT -d "$@" >/tmp/unfsd.log 2>&1 & sleep 1; pgrep -x unfsd >/dev/null || { cat /tmp/unfsd.log; exit 2; }; }
stop() { pkill -x unfsd; for i in 1 2 3 4 5 6; do pgrep -x unfsd >/dev/null || break; sleep 1; done; }
stats() { kill -USR1 "$(pgrep -x unfsd)"; sleep 1; grep "fh entries" /tmp/unfsd.log | tail -1 | awk '{for(i=1;i<=NF;i++){if($i=="miss")m=$(i+1)}} END{print m+0}'; }

run_case() { # name unfsd-options...
    local name=$1; shift
    stop; start "$@"; $H collect /mnt/cifs /tmp/stored.$name || { echo "collect failed"; fail=1; return; }
    stop; start "$@"                                   # restart: the cache is empty again
    strace -f -c -p "$(pgrep -x unfsd)" -o /tmp/strace.$name & local SP=$!; sleep 1
    local t0=$(date +%s.%N); read -r R_N R_BAD < <($H check /tmp/stored.$name); local t1=$(date +%s.%N)
    kill -INT $SP; wait $SP 2>/dev/null
    R_MISS=$(stats)
    R_STAT=$(awk '$NF ~ /^(newfstatat|lstat|stat|statx|fstatat64)$/ {s+=$4} END{print s+0}' /tmp/strace.$name)
    R_POLL=$(awk '$NF ~ /^p?poll$/ {s+=$4} END{print s+0}' /tmp/strace.$name)
    R_SECS=$(awk "BEGIN{printf \"%.1f\", $t1-$t0}")
    echo "      $name: handles=$R_N bad=$R_BAD misses=$R_MISS stat=$R_STAT poll=$R_POLL time=${R_SECS}s"
}

run_case learn -S auto -H 100000 -L
check "-L: every stored handle resolves to the same file" $([ "$R_N" = "$total" ] && [ "$R_BAD" = 0 ]; echo $?) "$R_N handles, $R_BAD bad"
check "-L: about one miss per directory, not per file" $([ "$R_MISS" -le $((NDIRS * 3)) ]; echo $?) "$R_MISS misses for $total files in $NDIRS directories"
check "-L: stats stay proportional to the tree" $([ "$R_STAT" -le $((total * 8)) ]; echo $?) "$R_STAT stat calls"
L_STAT=$R_STAT; L_SECS=$R_SECS; L_POLL=$R_POLL

run_case nolearn -S auto -H 100000
check "without -L: handles still resolve" $([ "$R_BAD" = 0 ]; echo $?) "$R_BAD bad"
check "without -L: unchanged behaviour (a walk per file)" $([ "$R_MISS" -gt $((total / 2)) ]; echo $?) "$R_MISS misses, $R_STAT stat calls, ${R_SECS}s (with -L: $L_STAT, ${L_SECS}s)"

run_case tiny -S auto -H 16 -L
check "-H 16 (eviction during the walk): handles resolve" $([ "$R_BAD" = 0 ]; echo $?) "$R_BAD bad"
check "-H 16: unfsd still running" $(pgrep -x unfsd >/dev/null; echo $?) "pid $(pgrep -x unfsd)"

run_case nostable -H 100000 -L
check "-L without -S: handles resolve" $([ "$R_BAD" = 0 ]; echo $?) "$R_BAD bad, $R_MISS misses"
# the RPC library polls on its own; the run without -S measures that share
EXTRA=$((L_POLL - R_POLL))
check "-S: at most one mount check per request, not one per stat" $([ "$EXTRA" -le $((total * 3 / 2)) ]; echo $?) "$EXTRA more poll calls than without -S, for $total requests and $L_STAT stats"
stop
[ $fail = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $fail
