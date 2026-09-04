#!/usr/bin/env bash
#
# Emits the bump work as a JSON array, for a workflow matrix:
#
#   [{"package":"croc","tag":"v11.3.5","version":"11.3.5"}]
#
# Every enrolled package whose upstream has a tag we are not packaging. There is
# no staleness threshold and no filtering: a different tag string is the whole
# rule. Decided 2026-08-29, with croc's six releases in five days as the known
# cost.
#
# Reads each package.conf from the tree rather than over HTTP, which is the one
# thing this gets for free from living in the same repository as the packages.

set -euo pipefail
shopt -s inherit_errexit

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upstream.sh
. "$HERE/upstream.sh"

PACKAGES_FILE="${PACKAGES_FILE:-packages.txt}"
ROOT="${ROOT:-.}"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# A native package is its own upstream: its version tracks the signing key, not
# a release feed, so a tag lookup says nothing about it.
is_native() {
    case "$(cat "$ROOT/$1/debian/source/format" 2>/dev/null)" in
        *native*) return 0 ;; *) return 1 ;;
    esac
}

# The loop is a function so tests can source this file and override latest_tag.
# Everything above is definitions, everything below runs.
plan() {
    local rows="" pkg conf ours upstream_url slug newest
    while read -r pkg; do
        case "$pkg" in ''|\#*) continue ;; esac
        pkg="${pkg%%[[:space:]]*}"

        conf="$ROOT/$pkg/package.conf"
        [ -f "$conf" ] || { printf 'SKIP %s: no package.conf\n' "$pkg" >&2; continue; }
        is_native "$pkg" && continue

        ours="$(sed -n 's/^VERSION=//p' "$conf" | head -n1)"
        upstream_url="$(sed -n 's/^UPSTREAM=//p' "$conf" | head -n1)"
        slug="${upstream_url#https://github.com/}"
        slug="${slug%.git}"
        [ -n "$ours" ] && [ -n "$slug" ] || { printf 'SKIP %s: package.conf incomplete\n' "$pkg" >&2; continue; }

        # A lookup that fails is not a package that is current. Reported and
        # skipped rather than silently treated as up to date.
        newest="$(latest_tag "$slug" || true)"
        [ -n "$newest" ] || { printf 'SKIP %s: no release or tag found for %s\n' "$pkg" "$slug" >&2; continue; }
        [ "$ours" != "$newest" ] || continue

        rows="$rows,{\"package\":\"$(json_escape "$pkg")\",\"tag\":\"$(json_escape "$newest")\"}"
    done < "$PACKAGES_FILE"

    printf '[%s]\n' "${rows#,}"
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

plan
