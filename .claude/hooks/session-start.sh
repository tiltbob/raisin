#!/bin/bash
# SessionStart hook for Claude Code cloud sessions.
#
# The cloud container is Ubuntu with no Swift toolchain, so this installs one and warms the
# EarDiggerKit build, so that the same command CI runs on Linux works straight away:
#   swift test --package-path EarDiggerKit
# The iOS app itself (EarDigger.xcodeproj) needs Xcode and cannot be built here.
#
# It only runs in cloud sessions (CLAUDE_CODE_REMOTE=true); on a Mac, Xcode provides swift.
# It is idempotent: an already-installed toolchain and already-present packages are skipped.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Pinned swift.org release (https://www.swift.org/install/linux/), verified by SHA-256.
SWIFT_VERSION="6.3.3"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_PLATFORM_DIR="ubuntu2404"
SWIFT_SHA256="da8272a5fddccd65b1529ed0e52e04526e2eadd4237d58d6220efeb973c6cd19"

SWIFT_HOME="/opt/swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}"
SWIFT_BIN="${SWIFT_HOME}/usr/bin"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

# 1. Packages the toolchain needs at run time (swift.org's list for Ubuntu 24.04).
if ! dpkg -s libz3-dev libxml2-dev libcurl4-openssl-dev libncurses-dev > /dev/null 2>&1; then
  echo "session-start: installing Swift runtime packages"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq --no-install-recommends \
    binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev \
    libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata unzip \
    zlib1g-dev
fi

# 2. The toolchain itself, under /opt.
if [ ! -x "${SWIFT_BIN}/swift" ]; then
  echo "session-start: installing Swift ${SWIFT_VERSION} into ${SWIFT_HOME}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  tarball="swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}.tar.gz"
  url="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM_DIR}/swift-${SWIFT_VERSION}-RELEASE/${tarball}"
  curl -sSfL --retry 3 -o "${tmp}/${tarball}" "$url"
  echo "${SWIFT_SHA256}  ${tmp}/${tarball}" | sha256sum -c -
  $SUDO mkdir -p "$SWIFT_HOME"
  $SUDO tar -xzf "${tmp}/${tarball}" -C "$SWIFT_HOME" --strip-components=1
fi

# 3. Put it on the PATH for this hook and, through CLAUDE_ENV_FILE, for the whole session.
export PATH="${SWIFT_BIN}:${PATH}"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"${SWIFT_BIN}:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
swift --version

# 4. Build the package and its tests now, so the first `swift test` in the session is quick
#    (the container is snapshotted after this hook; the build lives in EarDiggerKit/.build).
log="$(mktemp)"
if swift build --package-path "${PROJECT_DIR}/EarDiggerKit" --build-tests > "$log" 2>&1; then
  echo "session-start: EarDiggerKit and its tests built"
else
  echo "session-start: EarDiggerKit build failed:" >&2
  tail -n 60 "$log" >&2
  rm -f "$log"
  exit 1
fi
rm -f "$log"
