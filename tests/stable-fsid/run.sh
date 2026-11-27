#!/bin/bash
# Run the stable filesystem ID (-S) test in a privileged Rocky Linux 9 container.
# Needs Docker (or Podman via DOCKER=podman) and a host kernel with the
# cifs, nfs and nfsd filesystems available.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
exec "${DOCKER:-docker}" run --rm --privileged \
    -v "$src:/src:ro" \
    rockylinux:9 /src/tests/stable-fsid/in-container.sh
