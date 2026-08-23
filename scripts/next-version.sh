#!/usr/bin/env bash
# Derives the next release version from the Conventional Commit subjects on main.
#
# Prints key=value lines for the release workflow to read as step outputs, and
# exits non-zero when nothing since the previous release tag is worth releasing.

set -euo pipefail

cd "$(dirname "$0")/.."

PREVIOUS=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n 1)

if [ -n "$PREVIOUS" ]; then
    BASE="${PREVIOUS#v}"
    # The shared ancestor, not the tag itself, so a tag made off main still gives a usable range.
    RANGE="$(git merge-base "$PREVIOUS" HEAD)..HEAD"
else
    BASE="0.0.0"
    RANGE="HEAD"
fi

if [[ ! "$BASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Previous tag $PREVIOUS is not a plain vMAJOR.MINOR.PATCH tag." >&2
    exit 1
fi

BUMP="none"

while IFS= read -r COMMIT; do
    SUBJECT=$(git show -s --format=%s "$COMMIT")
    BODY=$(git show -s --format=%b "$COMMIT")

    if [[ ! "$SUBJECT" =~ ^([a-z]+)(\([^\)]*\))?(!)?: ]]; then
        continue
    fi

    if [ -n "${BASH_REMATCH[3]}" ] || [[ "$BODY" == *"BREAKING CHANGE:"* ]]; then
        BUMP="major"
        break
    fi

    case "${BASH_REMATCH[1]}" in
        feat)
            BUMP="minor"
            ;;
        fix | perf)
            if [ "$BUMP" = "none" ]; then
                BUMP="patch"
            fi
            ;;
    esac
done < <(git rev-list "$RANGE")

if [ "$BUMP" = "none" ]; then
    echo "Nothing to release since ${PREVIOUS:-the first commit}: no feat:, fix:, perf: or breaking change." >&2
    git log --format='  %s' "$RANGE" >&2
    exit 1
fi

IFS=. read -r MAJOR MINOR PATCH <<<"$BASE"

case "$BUMP" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
esac

echo "Next version is $MAJOR.$MINOR.$PATCH, a $BUMP bump from ${PREVIOUS:-nothing}." >&2

echo "version=$MAJOR.$MINOR.$PATCH"
echo "tag=v$MAJOR.$MINOR.$PATCH"
