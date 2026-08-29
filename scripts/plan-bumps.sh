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
# Set in CI. Without it the open-pull-request check is skipped, which is what
# makes this runnable offline and in the tests.
REPO="${GITHUB_REPOSITORY:-}"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# A native package is its own upstream: its version tracks the signing key, not
# a release feed, so a tag lookup says nothing about it.
is_native() {
    case "$(cat "$ROOT/$1/debian/source/format" 2>/dev/null)" in
        *native*) return 0 ;; *) return 1 ;;
    esac
}

rows=""
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

    # A lookup that fails is not a package that is current. Reported and skipped
    # rather than silently treated as up to date.
    newest="$(latest_tag "$slug" || true)"
    [ -n "$newest" ] || { printf 'SKIP %s: no release or tag found for %s\n' "$pkg" "$slug" >&2; continue; }
    [ "$ours" != "$newest" ] || continue

    # An open pull request for this exact version already carries the work, and
    # merging it is what changes package.conf on master. Without this check the
    # package stays "behind" and is rebuilt across three suites on every run
    # until someone merges: a week of an unmerged croc bump is 84 builds at six
    # hourly.
    #
    # Keyed on the version, not the package, so a genuinely newer upstream
    # release is never suppressed by an older pull request still sitting open.
    if [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
        # The same mapping bump-upstream.sh uses: strip the leading run of
        # non-digits, so lychee-v0.24.2 and v11.3.5 both become bare versions.
        upstream_version="${newest#"${newest%%[0-9]*}"}"
        want="bump/$pkg/$upstream_version-1"
        if gh pr list --repo "$REPO" --state open --json headRefName \
             --jq '.[].headRefName' 2>/dev/null | grep -qxF "$want"; then
            printf 'SKIP %s: %s is already open as %s\n' "$pkg" "$newest" "$want" >&2
            continue
        fi
    fi

done < "$PACKAGES_FILE"

printf '[%s]\n' "${rows#,}"
