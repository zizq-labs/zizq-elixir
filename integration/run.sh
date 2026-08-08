#!/usr/bin/env bash

# Run the Elixir client integration tests against a real Zizq server.
#
# Usage:
#   ./run.sh --binary /path/to/zizq
#   ./run.sh --binary /path/to/zizq --tarball /path/to/zizq-0.6.0.tar
#
# With no --tarball the package is built from the current source first.
# CI passes the artifact it already built, so the suite runs against
# the exact bytes that will be published.
#
# The server is started on a random OS-assigned port (--port 0) and the
# actual bound address is parsed from its JSON log output. The test
# receives ZIZQ_URL as an environment variable so it doesn't need to
# know about server lifecycle.
#
# The test runs in an isolated temp directory and builds against the
# unpacked Hex tarball, not the local source tree. Mix has no
# "install this tarball" verb, so the package is extracted and depended
# on by path. A path dependency pointing at `../` would compile files
# that never ship in the package — extracting first is what makes this
# a genuine round trip through the `:files` list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BINARY=""
TARBALL=""
LICENSE_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)      BINARY="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --tarball)     TARBALL="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --license-key) LICENSE_KEY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$BINARY" ]]; then
    echo "Usage: ./run.sh --binary /path/to/zizq [--tarball /path/to/zizq-x.y.z.tar] [--license-key KEY]"
    echo
    echo "  --tarball is optional. Omit it and the package is built from the"
    echo "  current source, which is what you want locally. CI passes the"
    echo "  artifact it already built and tested."
    exit 1
fi

if [[ ! -x "$BINARY" ]]; then
    echo "Error: binary not found or not executable: $BINARY"
    exit 1
fi

# Build from source when no artifact was supplied. Without this the
# obvious two-step (release.sh, then run.sh) silently tests whatever
# package happens to be lying in _build/release — so a forgotten
# rebuild shows up as "function undefined" errors against code that is
# plainly there in the working tree.
if [[ -z "$TARBALL" ]]; then
    echo "==> No --tarball given; building the package from source"
    "$SCRIPT_DIR/../release.sh" | sed 's/^/    /'
    VERSION="$(sed -n 's/^[[:space:]]*@version "\(.*\)"/\1/p' "$SCRIPT_DIR/../mix.exs" | head -1)"
    TARBALL="$SCRIPT_DIR/../_build/release/zizq-${VERSION}.tar"
fi

if [[ ! -f "$TARBALL" ]]; then
    echo "Error: tarball not found: $TARBALL"
    exit 1
fi

# Derive the version from the artifact's filename so the suite can
# assert it is testing the package it was handed, not a leftover.
EXPECTED_VERSION="$(basename "$TARBALL")"
EXPECTED_VERSION="${EXPECTED_VERSION#zizq-}"
EXPECTED_VERSION="${EXPECTED_VERSION%.tar}"

# --- Set up isolated work directory ---

WORKDIR="$(mktemp -d)"
SERVER_ROOT="$(mktemp -d)"

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR" "$SERVER_ROOT"
}
trap cleanup EXIT

echo "==> Setting up integration test (Elixir $(elixir --version | tail -1))"
echo "    Client version: ${EXPECTED_VERSION}"

# --- Unpack the tarball ---
#
# A Hex package is an uncompressed outer tar holding VERSION, CHECKSUM,
# metadata.config and contents.tar.gz. The sources live in the inner
# gzipped tar, hence the two steps.

echo "    Unpacking package..."
mkdir -p "$WORKDIR/pkg" "$WORKDIR/vendor/zizq"
tar -xf "$TARBALL" -C "$WORKDIR/pkg"
tar -xzf "$WORKDIR/pkg/contents.tar.gz" -C "$WORKDIR/vendor/zizq"

if [[ ! -f "$WORKDIR/vendor/zizq/mix.exs" ]]; then
    echo "Error: unpacked package has no mix.exs — is $TARBALL a Hex tarball?"
    exit 1
fi

# --- Stage the integration project ---

cp "$SCRIPT_DIR/mix.exs" "$WORKDIR/"
cp -r "$SCRIPT_DIR/test" "$WORKDIR/"

cd "$WORKDIR"
export ZIZQ_PKG_PATH="$WORKDIR/vendor/zizq"

echo "    Fetching dependencies..."
mix deps.get 2>&1 | sed 's/^/    /'

# --- Start the server ---

echo "    Starting Zizq server..."

# Start zizq with port 0 (OS-assigned) and JSON logging so we can
# parse the actual bound address from the log output.
SERVER_LOG="$(mktemp)"
SERVER_ARGS=(serve --port 0 --no-admin --root-dir "$SERVER_ROOT" --log-format json --log-level info)
if [[ -n "$LICENSE_KEY" ]]; then
    SERVER_ARGS+=(--license-key "$LICENSE_KEY")
fi

"$BINARY" "${SERVER_ARGS[@]}" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for the "listening" log line with api="primary" and extract the
# address. The key `api: "primary"` is a stable machine-readable field;
# the message text may change.
ZIZQ_URL=""
BOOT_TIMEOUT="${ZIZQ_SERVER_BOOT_TIMEOUT:-60}"
DEADLINE=$((SECONDS + BOOT_TIMEOUT))
while [[ $SECONDS -lt $DEADLINE ]]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Error: server exited unexpectedly:"
        cat "$SERVER_LOG"
        exit 1
    fi

    LINE="$(grep '"api":"primary"' "$SERVER_LOG" 2>/dev/null || true)"
    if [[ -n "$LINE" ]]; then
        ADDR="$(echo "$LINE" | jq -r '.fields.addr')"
        SCHEME="$(echo "$LINE" | jq -r '.fields.scheme')"
        ZIZQ_URL="${SCHEME}://${ADDR}"
        break
    fi

    sleep 0.1
done

if [[ -z "$ZIZQ_URL" ]]; then
    echo "Error: server did not report a listening address within ${BOOT_TIMEOUT}s."
    echo "       Set ZIZQ_SERVER_BOOT_TIMEOUT to allow longer."
    cat "$SERVER_LOG"
    exit 1
fi

echo "    Server listening on ${ZIZQ_URL}"

# --- Run tests ---

echo "    Running integration tests..."
ZIZQ_URL="$ZIZQ_URL" \
ZIZQ_EXPECTED_VERSION="$EXPECTED_VERSION" \
    mix test
