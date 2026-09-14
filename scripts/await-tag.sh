#!/usr/bin/env bash
#
# Wait for a release tag to appear, and fail when it never does.
#
#   scripts/await-tag.sh <tag>
#
# The land job dispatches release.yml and, until now, had no way to learn
# whether anything came of it. A release that plans nothing exits 0 on purpose
# -- that is the idempotency guard absorbing a re-run, a changelog edit that
# does not move the version, and a hand-pushed tag -- so a release that was
# correctly skipped and one that was silently dropped are the same green run.
#
# On 2026-09-13 ouch's dispatch resolved master to the tip BEFORE its own bump
# commit. release.yml read the pre-bump changelog, derived a tag that already
# existed, planned nothing and went green. Nothing retried: the six-hourly
# drift check asks only whether package.conf matches upstream, and it did. The
# archive served the previous version for twelve hours, until check-published.sh
# noticed from the other end.
#
# The sha now passed to release.yml is what stops that happening. This is the
# other half: the run that asked for a release is the run that finds out it did
# not happen, rather than a dashboard half a day later.
#
# The tag, not the run's conclusion, because the tag is what the archive
# actually consumes and what every other part of this pipeline treats as the
# idempotency key.

set -euo pipefail
shopt -s inherit_errexit

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"

# Ten minutes. A release dispatched while another is in flight queues behind it
# -- release.yml's concurrency group never cancels in progress -- and the land
# matrix is serialised, so with several packages bumping in one run each waits
# for the ones before it. Generous enough to ride that out, and well inside the
# land job's own timeout.
ATTEMPTS="${AWAIT_TAG_ATTEMPTS:-60}"
DELAY="${AWAIT_TAG_DELAY:-10}"

# Overridden in the tests, which have no network and no time to spend.
#
# The singular `git/ref/` endpoint, which is an exact match. The plural
# `git/refs/` is a PREFIX match returning an array, so it answers 200 for
# ouch/v0.8.3-1 on the strength of an unrelated ouch/v0.8.3-10.
#
# A 404 and a broken token are the same non-zero here, so an auth failure
# spends the full window before failing. That is the safe direction: it fails,
# loudly, rather than reporting a tag that is not there.
tag_exists() { # tag
    gh api "repos/$REPO/git/ref/tags/$1" >/dev/null 2>&1
}
nap() { sleep "$DELAY"; }

await_tag() { # tag
    local tag="${1:?usage: await-tag.sh <tag>}"
    local i=1
    [ -n "$REPO" ] || { printf 'await-tag: REPO is unset\n' >&2; return 1; }

    while [ "$i" -le "$ATTEMPTS" ]; do
        if tag_exists "$tag"; then
            printf 'release tag %s exists\n' "$tag"
            return 0
        fi
        # Never after the last attempt: an `[ ... ] && nap` here would also
        # take the loop's exit status from the comparison under set -e.
        if [ "$i" -lt "$ATTEMPTS" ]; then
            nap
        fi
        i=$((i + 1))
    done

    printf '::error::%s never appeared. The release was dispatched and nothing was tagged, so the archive will not be told about this version and the drift check will read the package as current.\n' \
        "$tag" >&2
    return 1
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

await_tag "${1:?usage: await-tag.sh <tag>}"
