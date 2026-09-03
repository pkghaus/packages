#!/usr/bin/env bash
#
# Is a release or an archive ingest running right now?
#
#   scripts/release-in-flight.sh   -> prints "yes" or "no", exit 0
#
# The published check compares a package's debian/changelog version against what
# the archive serves, and a release in progress looks exactly like one that
# failed: the changelog is on master and the archive is not caught up yet.
#
# On 2026-09-02 that produced a dashboard issue asserting "a release build
# failed after the changelog landed" about a release that was, at that moment,
# succeeding. The drift run started at 13:20:38Z and the release it accused at
# 13:20:39Z -- one second apart, and the release finished ninety seconds after
# the issue was filed. A dashboard that names a cause it has not established is
# worse than one that says nothing, because it is the only thing anyone reads.
#
# Both halves matter: the tag and the archive dispatch come from the release
# workflow here, and the publish itself is a separate run in the archive repo,
# so a package can be mid-flight with nothing running in this repository at all.
set -euo pipefail
shopt -s inherit_errexit

PACKAGES_REPO="${PACKAGES_REPO:-pkghaus/packages}"
ARCHIVE_REPO="${ARCHIVE_REPO:-pkghaus/apt}"

# `gh run list --status` takes one value, and queued and in_progress are both
# "not finished". Counted over the recent runs instead, which is one call per
# repo rather than one per status.
active() { # <repo> <workflow-or-empty>
    local repo="$1"
    local wf="${2-}"
    # Declared separately: bash does not expand an earlier assignment in the
    # same `local` when the later one is an array.
    local args
    local out
    args=(run list --repo "$repo" --limit 20 --json status)
    [ -z "$wf" ] || args+=(--workflow "$wf")
    # A non-numeric sentinel on failure, never 0: a zero here would mean
    # "nothing is running", which is the direction that files a false
    # accusation. The caller treats anything non-numeric as in flight.
    #
    # Empty counts as failure too. `|| printf unknown` covers a non-zero exit
    # but not a zero exit with no output, and an empty answer reached the
    # caller's numeric test as "", which is neither caught by its non-numeric
    # guard nor usable as a number.
    out="$(gh "${args[@]}" --jq '[.[] | select(.status != "completed")] | length' 2>/dev/null)" || out=""
    printf '%s' "${out:-unknown}"
}

# An API failure must not read as "nothing is running": that is the direction
# that files a false accusation. Unreachable counts as in flight.
r="$(active "$PACKAGES_REPO" release.yml)"
a="$(active "$ARCHIVE_REPO" '')"
# Each answer on its own. Concatenating them let a numeric one mask an empty
# one -- "" and "3" join to "3", which passes a non-numeric guard and then
# fails the arithmetic below as "". Empty is matched explicitly: it is not a
# non-digit character, so *[!0-9]* never caught it.
for answer in "$r" "$a"; do
    case "$answer" in
        '' | *[!0-9]*) printf 'yes\n'; exit 0 ;;
    esac
done

if [ "$r" -gt 0 ] || [ "$a" -gt 0 ]; then
    printf 'yes\n'
else
    printf 'no\n'
fi
