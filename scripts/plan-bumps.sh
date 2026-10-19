#!/usr/bin/env bash
#
#   scripts/plan-bumps.sh [skipped-file]
#
# Emits the bump work as a JSON array, for a workflow matrix:
#
#   [{"package":"croc","tag":"v11.3.5"}]
#
# Given a path, it also writes there every enrolled package it could not check,
# for the dashboard: [{"package":"zig","reason":"..."}]. A skipped package is
# not a current one, and a SKIP line in the log reaches nobody.
#
# Every enrolled package whose upstream has a tag we are not packaging. There is
# no staleness threshold and no filtering: a different tag string is the whole
# rule, with croc's six releases in five days as the accepted cost.
#
# Reads each package.conf from the tree rather than over HTTP, which is the one
# thing this gets for free from living in the same repository as the packages.

set -euo pipefail
shopt -s inherit_errexit

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"
# shellcheck source=scripts/upstream.sh
. "$HERE/upstream.sh"

PACKAGES_FILE="${PACKAGES_FILE:-packages.txt}"
ROOT="${ROOT:-.}"

# Logs a skip and records it in plan()'s local `skipped`, which it is only ever
# called from.
plan_skip() { # package reason
    printf 'SKIP %s: %s\n' "$1" "$2" >&2
    skipped="$skipped,{\"package\":\"$(json_escape "$1")\",\"reason\":\"$(json_escape "$2")\"}"
}

# The loop is a function so tests can source this file and override latest_tag.
# Everything above is definitions, everything below runs.
plan() {
    local skipped_file="${1:-}" rows="" skipped="" pkg conf ours upstream_url host slug newest
    while read -r pkg || [ -n "$pkg" ]; do
        case "$pkg" in ''|\#*) continue ;; esac
        pkg="${pkg%%[[:space:]]*}"

        conf="$ROOT/$pkg/package.conf"
        [ -f "$conf" ] || { plan_skip "$pkg" "no package.conf"; continue; }
        is_native "$ROOT/$pkg" && continue

        ours="$(sed -n 's/^VERSION=//p' "$conf" | head -n1)"
        upstream_url="$(sed -n 's/^UPSTREAM=//p' "$conf" | head -n1)"
        # Host and slug, rather than stripping one hardcoded prefix. The old
        # form left a Codeberg URL intact, so the "slug" was the whole URL, the
        # API path became repos/https://codeberg.org/o/r/releases/latest, and
        # the package reported no upstream release forever without erroring.
        # That silence is part of why ly was written off as unpackageable.
        host="${upstream_url#https://}"
        host="${host%%/*}"
        slug="${upstream_url#https://"$host"/}"
        slug="${slug%.git}"
        [ -n "$host" ] && [ "$host" != "$upstream_url" ] || {
            plan_skip "$pkg" "cannot read a host out of UPSTREAM=$upstream_url"
            continue
        }
        [ -n "$ours" ] && [ -n "$slug" ] || { plan_skip "$pkg" "package.conf incomplete"; continue; }

        # A lookup that fails is not a package that is current. Recorded and
        # skipped rather than silently treated as up to date. latest_tag has
        # already logged the cause, which the reason points at.
        newest="$(latest_tag "$slug" "$host" || true)"
        [ -n "$newest" ] || {
            plan_skip "$pkg" "upstream lookup failed for $host/$slug; the plan log names the cause"
            continue
        }
        [ "$ours" != "$newest" ] || continue

        rows="$rows,{\"package\":\"$(json_escape "$pkg")\",\"tag\":\"$(json_escape "$newest")\"}"
    done < "$PACKAGES_FILE"

    if [ -n "$skipped_file" ]; then
        printf '[%s]\n' "${skipped#,}" > "$skipped_file"
    fi
    printf '[%s]\n' "${rows#,}"
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

plan "${1:-}"
