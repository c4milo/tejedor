#!/usr/bin/env bash
#
# linux_bench: runs the probe of the context switch that `zig build bench-linux` installed under
# zig-out/linux-bench/, in a Linux container, and prints its report.
#
#     zig build bench-linux && bash tools/linux_bench.sh --machine orbstack
#
# Each argument goes to the probe. The probe runs on the platform of Docker's host, on the Linux
# kernel of Docker's virtual machine. On the development Mac that virtual machine is `orbstack`.
#
# BENCH_PLATFORM names another platform, such as linux/amd64. On a host of another processor the
# probe then runs under an emulator. Such a run shows that the probe runs there. Its numbers
# measure the emulator, and they go in no result.
#
# Standard output holds the report of the probe, and then a table with the load of the host
# before and after the run. A container does not see that load: its load average is the load of
# the Linux kernel of the virtual machine. So a result of a container needs both.
#
# The host kills a container that runs longer than the limit of tools/docker_limit.sh.
#
# The install must be newer than each source, as in tools/linux_test.sh. `zig build bench-linux`
# touches a stamp file after its last install.

set -euo pipefail

# The container image: the pinned image of tools/linux_test.sh.
readonly image='alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
# The directory that `zig build bench-linux` installs into, from the top of the work tree.
readonly install_directory='zig-out/linux-bench'
# The file that `zig build bench-linux` touches after its last install (build/bench.zig).
readonly stamp_name='.bench-linux-stamp'
# The first part of the name of an installed probe. The processor follows it.
readonly probe_prefix='switch_probe-'
# Each path that holds a source of the probe, from the top of the work tree.
readonly source_paths=(src bench build build.zig build.zig.zon)
# The place of the install directory in the container. The mount is read-only.
readonly mount_point='/t'
# The place of the probe when it runs, on the container's own filesystem.
readonly run_directory='/tmp/bin'

cd "$(dirname "$0")/.."
# shellcheck source=tools/docker_limit.sh
source tools/docker_limit.sh
readonly out="$PWD/$install_directory"
readonly stamp="$out/$stamp_name"

# Prints the reason that the run cannot continue, and ends it.
fail() {
  echo "linux_bench: $*" >&2
  exit 1
}

# The name of the installed probe for a Docker platform.
probe_of() {
  case "$1" in
    linux/arm64) echo "${probe_prefix}aarch64" ;;
    linux/amd64) echo "${probe_prefix}x86_64" ;;
    *) fail "no probe is built for the platform $1" ;;
  esac
}

if [[ ! -f "$stamp" ]]; then
  fail "$stamp is missing; run 'zig build bench-linux' first"
fi
stale="$(find "${source_paths[@]}" -type f \( -name '*.zig' -o -name '*.zon' \) \
  -newer "$stamp" -print -quit)"
if [[ -n "$stale" ]]; then
  fail "$stale is newer than the install; run 'zig build bench-linux' again"
fi
if ! command -v docker >/dev/null 2>&1; then
  fail "no docker on PATH"
fi

# The answers of docker and of uptime go through a file, and not a command substitution around
# a container, as in tools/linux_test.sh.
temporary_directory="${TMPDIR:-/tmp}"
answer_file="$(mktemp "${temporary_directory%/}/tejedor-linux-bench.XXXXXX")"
readonly answer_file
trap 'docker_limit_end; rm -f "$answer_file"' EXIT
if ! docker version --format '{{.Server.Os}}/{{.Server.Arch}}' >"$answer_file"; then
  fail "docker did not answer; start Docker and run this again"
fi
host_platform="$(cat "$answer_file")"
readonly host_platform
readonly platform="${BENCH_PLATFORM:-$host_platform}"
probe="$(probe_of "$platform")"
readonly probe
if [[ ! -f "$out/$probe" ]]; then
  fail "$out/$probe is missing; run 'zig build bench-linux' first"
fi
if [[ "$platform" != "$host_platform" ]]; then
  echo "linux_bench: $platform is not the platform of Docker's host, $host_platform, so the" \
    "probe runs under an emulator, and its numbers measure the emulator" >&2
fi

load_before="$(uptime)"
# The inner script takes the mount point, the run directory and the name as its first arguments,
# and hands each other argument to the probe.
# shellcheck disable=SC2016
if ! docker_limit_run "$probe" '' --rm --platform "$platform" \
  --volume "$out:$mount_point:ro" "$image" \
  sh -c 'mkdir -p "$2" && cp "$1/$3" "$2/" && probe="$2/$3" && shift 3 && exec "$probe" "$@"' \
  sh "$mount_point" "$run_directory" "$probe" "$@"; then
  fail "$probe failed on $platform"
fi
load_after="$(uptime)"

cat <<EOF

The probe ran in a container on $platform. A container does not see the load of its host. On
the host, \`uptime\` gave:

| when | \`uptime\` on the host |
|---|---|
| before the run | ${load_before# } |
| after the run | ${load_after# } |
EOF
