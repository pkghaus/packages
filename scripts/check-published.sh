#!/usr/bin/env bash
#
# Emits the packages whose debian/changelog version is not what the archive
# serves, as a JSON array:
#
#   [{"package":"ouch","packaged":"0.8.2-1","published":"0.8.1-1"}]
#
# The drift check asks one question -- does package.conf match upstream -- and a
# package that is packaged but never published answers it "yes". Consider: the
# bump lands, the release build's arm64 leg fails, no tag is cut and nothing
# publishes. package.conf now says 0.8.3 and so does upstream, so every later
# drift run calls the package current while users are served 0.8.2, forever.
# Nothing retries and nothing reports it, because "behind the archive" was not a
# state anything could name.
#
# unstable, because its version carries no suite qualifier and so compares
# directly against the changelog. Both architectures, because a publish that
# landed one and not the other is the same kind of stuck.

set -euo pipefail
shopt -s inherit_errexit

PACKAGES_FILE="${PACKAGES_FILE:-packages.txt}"
ROOT="${ROOT:-.}"
ARCHIVE_BASE="${ARCHIVE_BASE:-https://apt.pkg.haus}"
ARCHES="${ARCHES:-amd64 arm64}"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

changelog_version() {
    sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p' "$ROOT/$1/debian/changelog"
}

# Overridden in the tests, which have no network. Anything that prints a
# Packages file works.
fetch_index() { # arch
    # Retried: a blip here skips the published check for six hours, and the
    # whole point of that check is that nothing else notices a package which
    # landed but never reached the archive. Failing is still safe -- the caller
    # reports nothing rather than inventing 25 stuck packages -- so this only
    # makes the safe outcome rarer.
    curl -fsSL --max-time 60 --retry 3 --retry-all-errors --retry-delay 2 \
        "$ARCHIVE_BASE/dists/unstable/main/binary-$1/Packages"
}

# "Package: x\nVersion: y" -> "x y", for the whole index in one pass.
index_pairs() {
    awk '/^Package: /{p=$2} /^Version: /{if(p!=""){print p, $2; p=""}}'
}

published() {
    local rows="" pkg packaged arch idx found ver
    for arch in $ARCHES; do
        idx="$(fetch_index "$arch" | index_pairs)" || {
            printf 'cannot read the %s index; not reporting\n' "$arch" >&2
            return 1
        }
        printf '%s\n' "$idx" > "$TMP/index.$arch"
    done

    while read -r pkg; do
        case "$pkg" in ''|\#*) continue ;; esac
        pkg="${pkg%%[[:space:]]*}"
        [ -f "$ROOT/$pkg/debian/changelog" ] || continue
        packaged="$(changelog_version "$pkg")"
        [ -n "$packaged" ] || continue

        for arch in $ARCHES; do
            ver="$(awk -v p="$pkg" '$1==p {print $2; exit}' "$TMP/index.$arch")"
            found="${ver:-<absent>}"
            [ "$found" = "$packaged" ] && continue
            rows="$rows,{\"package\":\"$(json_escape "$pkg")\""
            rows="$rows,\"arch\":\"$(json_escape "$arch")\""
            rows="$rows,\"packaged\":\"$(json_escape "$packaged")\""
            rows="$rows,\"published\":\"$(json_escape "$found")\"}"
        done
    done < "$PACKAGES_FILE"

    printf '[%s]\n' "${rows#,}"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

published
