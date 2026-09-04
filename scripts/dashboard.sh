#!/usr/bin/env bash
#
# Create, update, close or leave the drift dashboard issue.
#
#   scripts/dashboard.sh <body-file> <verified> <published-checked> <run-url>
#
# <verified> and <published-checked> are "yes" or "no": whether this run
# actually performed each of the two checks the dashboard reports on.
#
# The rendering decision lives in drift-report.sh, which produces a body when
# something is wrong and nothing when nothing is. This owns the other half --
# what to do with that answer -- and the GitHub calls that carry it out.
#
# It is a script rather than thirty lines inside bump.yml because that is the
# one decision in the whole pipeline nobody else makes: whether a failure gets
# reported at all. Every other script here is tested; this was YAML, and this
# repository's own comments record four production bugs in workflow shell --
# a `&& 0 ||` that is always 1, a diff whose failure vanished inside a
# pipeline, an `&&` that killed a step whose right answer was "nothing to do",
# and an inverted `format()`. None of them could have had a test where they sat.
#
# The exact-title match is done here rather than with `gh --jq` for the same
# reason: a jq program embedded in a workflow argument is not reachable by a
# test either. Search is not used at all -- it is fuzzy, and it eventually
# latches onto the wrong issue.

set -euo pipefail
shopt -s inherit_errexit

body_file="${1:?usage: dashboard.sh <body-file> <verified> <published-checked> <run-url>}"
verified="${2:?}"
published_checked="${3:?}"
run_url="${4:?}"

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
TITLE="${TITLE:-Upstream release drift}"
MENTION="${MENTION:-@pkghaus/maintainers}"

[ -n "$REPO" ] || { echo "dashboard: REPO is unset" >&2; exit 1; }

open_issue_number() {
    gh issue list --repo "$REPO" --state open --json number,title --limit 100 \
        | TITLE="$TITLE" python3 -c '
import json, os, sys
title = os.environ["TITLE"]
for issue in json.load(sys.stdin):
    if issue.get("title") == title:
        print(issue["number"])
        break
'
}

number="$(open_issue_number)"

if [ -s "$body_file" ]; then
    if [ -z "$number" ]; then
        # The mention goes in the opening body only. Mentioning is what
        # subscribes the team; repeating it on every rewrite would be noise,
        # and being subscribed is what makes later edits reach them anyway.
        opening="$(mktemp)"
        { printf '%s\n\n' "$MENTION"; cat "$body_file"; } > "$opening"
        gh issue create --repo "$REPO" --title "$TITLE" --body-file "$opening"
        rm -f "$opening"
    else
        gh issue edit "$number" --repo "$REPO" --body-file "$body_file"
    fi
    exit 0
fi

# Nothing to report is not the same as nothing being wrong. The published check
# is skipped while a release is in flight or the archive is unreadable, and a
# push run verifies nothing. With either missing, leave the issue alone and let
# the next run decide.
if [ "$published_checked" != yes ] || [ "$verified" != yes ]; then
    echo "nothing to report, but a check was skipped; leaving the issue as it is"
    exit 0
fi

if [ -n "$number" ]; then
    gh issue close "$number" --repo "$REPO" \
        --comment "Every enrolled package matches its newest upstream release and the archive serves it. Checked by $run_url"
else
    echo "nothing to report"
fi
