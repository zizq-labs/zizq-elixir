#!/usr/bin/env bash
set -euo pipefail

# Bump the package version.
#
# Usage:
#   ./bump-version.sh              # increment the trailing number
#   ./bump-version.sh 0.6.0        # set an explicit version
#
# The no-argument form increments whatever number sits after the final
# dot, which does the right thing for both release and pre-release
# versions:
#
#   0.6.0          -> 0.6.1
#   0.6.0-alpha.2  -> 0.6.0-alpha.3
#
# Moving between the two (alpha -> release, or release -> a new
# pre-release series) is a deliberate act, so pass the version
# explicitly for that.
#
# Updates:
#   - mix.exs (@version)
#   - CHANGELOG.md (adds a new section header for the new version)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CURRENT="$(sed -n 's/^[[:space:]]*@version "\(.*\)"/\1/p' mix.exs | head -1)"

if [ -z "$CURRENT" ]; then
    echo "Error: could not read @version from mix.exs"
    exit 1
fi

if [ $# -ge 1 ]; then
    NEW="$1"
else
    # Split on the final dot: everything before it is carried through
    # unchanged, the trailing number is incremented.
    PREFIX="${CURRENT%.*}"
    LAST="${CURRENT##*.}"

    if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
        echo "Error: cannot auto-increment '${CURRENT}' — the component after"
        echo "the final dot ('${LAST}') is not a number."
        echo "Pass an explicit version, e.g. ./bump-version.sh 0.6.0"
        exit 1
    fi

    NEW="${PREFIX}.$((LAST + 1))"
fi

if [ "$NEW" = "$CURRENT" ]; then
    echo "Already at version ${CURRENT}."
    exit 0
fi

echo "Bumping version: ${CURRENT} -> ${NEW}"

sed -i "0,/^\([[:space:]]*\)@version \"${CURRENT}\"/s//\1@version \"${NEW}\"/" mix.exs
echo "  Updated mix.exs"

# Update docs
sed -i "s/\"~> ${CURRENT}\"/\"~> ${NEW}\"/" docs/src/installation.md
sed -i "s/\"~> ${CURRENT}\"/\"~> ${NEW}\"/" README.md

# Add a new CHANGELOG section if it doesn't already exist.
CHANGELOG="CHANGELOG.md"
if [ -f "$CHANGELOG" ] && ! grep -q "^## ${NEW}$" "$CHANGELOG" 2>/dev/null; then
    sed -i "0,/^## /s//## ${NEW}\n\n\n## /" "$CHANGELOG"
    echo "  Added ${CHANGELOG} section for ${NEW}"
fi

echo "Done. Version is now ${NEW}."
echo ""
echo "Next steps:"
echo "  1. Edit ${CHANGELOG} with release notes"
echo "  2. Commit: git add -A && git commit -m \"Bump version to ${NEW}\""
