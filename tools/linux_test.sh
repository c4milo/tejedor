#!/usr/bin/env bash
#
# linux_test: runs each test executable that `zig build test-linux` installed under
# zig-out/linux/, each in a Linux container of its own, and stops at the first one that fails.
# The executables hold the unit tests of the package and those of the bench programs.
#
#     zig build test-linux && bash tools/linux_test.sh
#     bash tools/linux_test.sh linux/arm64        # the executables of one platform alone
#
# The check of step 0 of the build order names three platforms: aarch64 macOS, aarch64 Linux and
# x86-64 Linux (rotor's decision 34, "Build order"). The development machine is a Mac on aarch64.
# `zig build test` runs the tests there. This script runs them on the Linux kernel of Docker's
# virtual machine, for both processors and in both modes.
#
# Docker runs an executable of the host's own processor on that processor. It runs an executable
# of the other processor under an emulator, and the script says so before the first test. A pass
# under an emulator shows that the emulator ran the code. A real x86-64 processor runs the tests
# in CI, where `zig build test` runs on a Linux runner.
#
# The script runs the tests by the manifest that `zig build test-linux` writes. Each line holds
# a Docker platform and the name of an executable. The script never runs a file that it only
# finds in the directory. So it does not run an executable that is there from an earlier build,
# and a listed executable that is missing fails the run.
#
# Each executable runs in a container of its own, so a test cannot leave a file for the next
# one. The script copies it from the read-only mount to the container's own filesystem
# before it runs. A build on the host during the run then cannot replace the file under it.
#
# The host kills a container that runs longer than the limit of tools/docker_limit.sh. The run
# then fails, and the script prints the name of the executable that hung.
#
# The install under zig-out/linux/ must be newer than each source. If it is older, the run
# passes on executables that are older than the tree. `zig build test-linux` touches a stamp
# file after its last install, and the script refuses to run when a source is newer than the
# stamp.
#
# The tests of step 0 enter no io_uring, so each container runs under Docker's default seccomp
# profile. Step 1 adds the runs with io_uring and with epoll (rotor's decision 34, "Upkeep").

set -euo pipefail

# The container image, pinned by digest so that each run executes the same bytes. It is alpine
# 3.20, the image of rotor's Linux gate. The executables are static and take nothing from the
# image. So the image supplies only a shell, `cp` and `uname`. The digest names an index of
# several platforms, so the same line serves arm64 and amd64. To move the pin, read the new
# digest with `docker buildx imagetools inspect alpine:3.20`.
readonly image='alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
# The directory that `zig build test-linux` installs into, from the top of the work tree.
readonly install_directory='zig-out/linux'
# The file that `zig build test-linux` touches after its last install (build/linux.zig).
readonly stamp_name='.test-linux-stamp'
# The file that lists the installed test executables: a platform and a name on each line.
readonly manifest_name='tests.manifest'
# Each path that holds a source of an installed executable, from the top of the work tree. The
# script compares only the .zig and .zon files under them with the stamp.
readonly source_paths=(src bench build build.zig build.zig.zon)
# The place of the install directory in the container. The mount is read-only.
readonly mount_point='/t'
# The place of an executable when it runs, on the container's own filesystem.
readonly run_directory='/tmp/bin'

cd "$(dirname "$0")/.."
# shellcheck source=tools/docker_limit.sh
source tools/docker_limit.sh
readonly out="$PWD/$install_directory"
readonly stamp="$out/$stamp_name"
readonly manifest="$out/$manifest_name"
# The platforms that the caller asked for. With none, each platform of the manifest runs.
readonly wanted_platforms=("$@")

# Prints the reason that the run cannot continue, and ends it.
fail() {
  echo "linux_test: $*" >&2
  exit 1
}

# Refuses an install that is missing, empty, or older than a source.
require_fresh_install() {
  local required stale
  for required in "$stamp" "$manifest"; do
    if [[ ! -f "$required" ]]; then
      fail "$required is missing; run 'zig build test-linux' first"
    fi
  done
  if [[ ! -s "$manifest" ]]; then
    fail "$manifest lists no test executable"
  fi
  stale="$(find "${source_paths[@]}" -type f \( -name '*.zig' -o -name '*.zon' \) \
    -newer "$stamp" -print -quit)"
  if [[ -n "$stale" ]]; then
    fail "$stale is newer than the install; run 'zig build test-linux' again"
  fi
}

# Returns 0 when the caller asked for the platform, or asked for none.
wanted() {
  local platform="$1"
  local each
  if [[ ${#wanted_platforms[@]} -eq 0 ]]; then
    return 0
  fi
  for each in "${wanted_platforms[@]}"; do
    if [[ "$each" == "$platform" ]]; then
      return 0
    fi
  done
  return 1
}

# Runs one command in a new container of the given platform, with the install directory mounted
# read-only. The second argument names the thing that runs, for the message of a run that reaches
# the time limit of tools/docker_limit.sh.
in_container() {
  local platform="$1"
  local label="$2"
  shift 2
  docker_limit_run "$label" '' --rm --platform "$platform" \
    --volume "$out:$mount_point:ro" "$image" "$@"
}

# Prints the kernel and the processor that a container of the platform sees. The container
# prints the line itself. A command substitution here could leave the watcher of
# tools/docker_limit.sh behind after an interrupt.
describe() {
  local platform="$1"
  # shellcheck disable=SC2016
  if ! in_container "$platform" "uname on $platform" sh -c \
    'model="$(sed -n "s/^model name[^:]*: *//p" /proc/cpuinfo | head -n 1)"
     echo "linux_test: $1: kernel $(uname -r), machine $(uname -m), processor ${model:-not named}"' \
    sh "$platform"; then
    fail "docker could not run a container of $platform; start Docker and run this again"
  fi
  if [[ "$platform" != "$host_platform" ]]; then
    echo "linux_test: $platform is not the platform of Docker's host, $host_platform," \
      "so its tests run under an emulator"
  fi
}

# Copies one installed executable into a container of the platform and runs it there. The inner
# script takes the mount point, the run directory and the name as its arguments. So the shell of
# the container expands them, and this shell does not.
run() {
  local platform="$1"
  local name="$2"
  if [[ ! -f "$out/$name" ]]; then
    fail "$name is in the manifest and not in $install_directory; run 'zig build test-linux'"
  fi
  echo "linux_test: $name on $platform"
  # shellcheck disable=SC2016
  if ! in_container "$platform" "$name" \
    sh -c 'mkdir -p "$2" && cp "$1/$3" "$2/" && exec "$2/$3"' \
    sh "$mount_point" "$run_directory" "$name"; then
    fail "$name failed on $platform; nothing after it was run"
  fi
}

require_fresh_install

if ! command -v docker >/dev/null 2>&1; then
  fail "no docker on PATH"
fi
# The platform of the machine that Docker's daemon runs on, in the words of `--platform`. The
# answer goes through a file and not a command substitution, as rotor's gate reads its release.
temporary_directory="${TMPDIR:-/tmp}"
answer_file="$(mktemp "${temporary_directory%/}/tejedor-linux-test.XXXXXX")"
readonly answer_file
trap 'docker_limit_end; rm -f "$answer_file"' EXIT
if ! docker version --format '{{.Server.Os}}/{{.Server.Arch}}' >"$answer_file"; then
  fail "docker did not answer; start Docker and run this again"
fi
host_platform="$(cat "$answer_file")"
readonly host_platform

# The platforms of the manifest, each one time, in the order of the manifest.
described=' '
ran=0
# Standard input is the manifest here. docker_limit_run closes it for docker, so a container
# cannot read the names that are still to come.
while read -r platform name; do
  if [[ -z "${platform:-}" ]]; then
    continue
  fi
  if [[ -z "${name:-}" ]]; then
    fail "the manifest line '$platform' names no executable"
  fi
  if ! wanted "$platform"; then
    continue
  fi
  if [[ "$described" != *" $platform "* ]]; then
    describe "$platform"
    described="$described$platform "
  fi
  run "$platform" "$name"
  ran=$((ran + 1))
done <"$manifest"

if ((ran == 0)); then
  fail "no executable of the manifest is of a platform that was asked for: ${wanted_platforms[*]-}"
fi
echo "linux_test: all $ran passed"
