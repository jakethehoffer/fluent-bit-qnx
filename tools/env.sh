# Source this file (do not run it): sets up QNX SDP 8.0 and the paths used by tools/.
#
#   source tools/env.sh
#
# Every value can be overridden by exporting it before sourcing.
FBQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FBQ_ROOT

# QNX SDP 8.0 (sets QNX_HOST, QNX_TARGET and puts qcc on PATH).
# shellcheck disable=SC1091
source "${QNX_SDP:-$HOME/qnx800}/qnxsdp-env.sh" >/dev/null

# Build output stays on the Linux filesystem (much faster than /mnt/c).
export FBQ_BUILD="${FBQ_BUILD:-$HOME/build/fluent-bit-qnx}"

# Where the pinned upstream tarball is cached (downloaded only when missing or wrong).
export FBQ_TARBALL_CACHE="${FBQ_TARBALL_CACHE:-$HOME/.cache/fluent-bit-qnx}"

# QEMU target, shared with the qnx-ipc project (user-mode networking, SSH on a forwarded port).
export QNX_IMAGE_DIR="${QNX_IMAGE_DIR:-$HOME/qnx-images/ipc}"
export QNX_SSH_PORT="${QNX_SSH_PORT:-2222}"
export QNX_SSH_KEY="${QNX_SSH_KEY:-$HOME/.ssh/qnx_target_ed25519}"

# Install location on the target: bin/fluent-bit, lib/ (extra SDP libraries), etc.
export FBQ_TARGET_DIR="${FBQ_TARGET_DIR:-/data/fluent-bit-qnx}"

# SSH options for the target (no spaces inside values, so word splitting is safe).
export FBQ_SSH_OPTS="-i $QNX_SSH_KEY -p $QNX_SSH_PORT -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

# fbq_ssh <command...>: run a command on the target (the command string is run by the
# target's shell). fbq_scp <local...> <remote-dir>: copy files to the target.
fbq_ssh() {
  # shellcheck disable=SC2086
  ssh $FBQ_SSH_OPTS root@127.0.0.1 "$@"
}
fbq_scp() {
  local dest="${*: -1}"
  local -a src=("${@:1:$#-1}")
  # Legacy scp protocol (-O), as the spike and qnx-ipc use against this image.
  scp -O -i "$QNX_SSH_KEY" -P "$QNX_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
      "${src[@]}" "root@127.0.0.1:$dest"
}
