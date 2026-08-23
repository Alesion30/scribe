#!/usr/bin/env bash
# Writes a version string into the scribe command configuration.
#
# The release workflow calls this from both a macOS and a Linux runner, so the
# edit goes through perl rather than the sed -i spellings that differ there.

set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="Sources/scribe/Scribe.swift"
VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: scripts/set-version.sh <major.minor.patch>" >&2
    exit 1
fi

# Anchoring on the leading indent keeps the pattern off the inversion: flags further down the file.
VERSION="$VERSION" perl -pi -e 's/^(\s*version: )"[^"]*"/$1"$ENV{VERSION}"/' "$SOURCE"

if ! grep -Fq "version: \"$VERSION\"," "$SOURCE"; then
    echo "Could not write version $VERSION into $SOURCE" >&2
    exit 1
fi
