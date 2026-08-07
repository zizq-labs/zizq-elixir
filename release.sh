#!/usr/bin/env bash

# Build release artifacts for the Zizq Elixir client.
#
# Produces:
#   _build/release/zizq-<version>.tar
#   _build/release/zizq-<version>.tar.sha256
#
# Usage:
#   ./release.sh            # build only
#   ./release.sh --check    # verify format + compile + tests pass first
#
# Hex tarballs are reproducible (internal timestamps are pinned), so
# rebuilding an unchanged tree produces a byte-identical artifact. The
# `Package checksum:` Hex prints is the SHA-256 of the tarball itself,
# so the `.sha256` written here is a cross-check of Hex's own figure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Read the version from mix.exs directly rather than via `mix eval`, so
# this works (and reports a sensible version) even when the project
# doesn't compile. `bump-version.sh` writes the same line.
VERSION="$(sed -n 's/^[[:space:]]*@version "\(.*\)"/\1/p' mix.exs | head -1)"

if [ -z "$VERSION" ]; then
    echo "Error: could not read @version from mix.exs"
    exit 1
fi

TARBALL="zizq-${VERSION}.tar"
OUT_DIR="_build/release"

echo "==> Zizq Elixir Client v${VERSION}"

# Optional pre-flight checks.
if [[ "${1:-}" == "--check" ]]; then
    echo "    Checking formatting..."
    mix format --check-formatted

    echo "    Compiling (warnings as errors)..."
    mix compile --force --warnings-as-errors

    echo "    Running tests..."
    mix test
    shift
fi

echo "    Building package..."
mkdir -p "$OUT_DIR"
mix hex.build --output "${OUT_DIR}/${TARBALL}"

echo "    Computing checksum..."
(cd "$OUT_DIR" && shasum -a 256 "$TARBALL" > "${TARBALL}.sha256")

echo "==> Done."
echo "    ${OUT_DIR}/${TARBALL}"
echo "    ${OUT_DIR}/${TARBALL}.sha256"
