#!/usr/bin/env bash
#
# Renders the drift dashboard body from a plan.
#
#   scripts/drift-report.sh <matrix-json> <status-tsv> <stuck-json> <run-url>
#
# One issue, rewritten each run. Since bumps land on master directly there is no
# pull request to be the work and this to be its index: the issue is the only
# place any of it is visible, so it has to carry everything a person watching
# merges would otherwise have noticed.
#
# Two things it now says that it did not:
#
# Per-package verification status. It used to print one line for the whole run,
# "verification did not pass for every package". You could still tell which
# package it meant, because a failed one got no pull request and its link column
# was empty -- that column was doing double duty as a status by accident. With
# no pull requests there is no accident left to rely on.
#
# Packaged but not published. If a release build fails after the changelog is
# already on master, package.conf matches upstream and every later drift run
# calls the package current while the archive serves the old version. Nothing
# retries it and, until this table, nothing named it.

# Two deliberate single-quotings that shellcheck reads as mistakes: the python3
# body must not be expanded by the shell, and the backticks in the markdown are
# code formatting rather than command substitution.
# shellcheck disable=SC2016

set -euo pipefail
shopt -s inherit_errexit

matrix="${1:?matrix json}"
status_tsv="${2-}"
stuck="${3:-[]}"
run_url="${4:?run url}"

export STATUS_TSV="$status_tsv"

printf '%s' "$matrix" | python3 -c '
import json, sys, os

# "<package>\t<status>" from verify-status.sh. A package missing from it is
# unknown rather than fine: see the note there.
status = {}
for line in os.environ.get("STATUS_TSV", "").splitlines():
    if "\t" in line:
        pkg, st = line.split("\t", 1)
        status[pkg] = st.strip()

# What the reader needs to do about it, not what the runner called it.
WORDS = {
    "success":   "landed, releasing",
    "failure":   "**verification failed**",
    "cancelled": "**verification cancelled**",
    "unknown":   "**not verified**",
}

rows = json.load(sys.stdin)
print("| package | upstream tag | status |")
print("|---|---|---|")
for e in rows:
    pkg, tag = e["package"], e["tag"]
    st = status.get(pkg, "unknown")
    word = WORDS.get(st) or ("**" + st + "**")
    print("| `%s` | `%s` | %s |" % (pkg, tag, word))
'

printf '\n'

# The second table only when there is one. An empty section on every render
# teaches the reader to skip the area it will one day appear in.
if [ "$stuck" != "[]" ] && [ -n "$stuck" ]; then
    printf '### Packaged but not published\n\n'
    printf 'These carry a `debian/changelog` version the archive does not serve. A release build failed after the changelog landed, so nothing retries and the drift check above reports them current.\n\n'
    printf '%s' "$stuck" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print("| package | arch | packaged | published |")
print("|---|---|---|---|")
for r in rows:
    print("| `%s` | %s | `%s` | `%s` |"
          % (r["package"], r["arch"], r["packaged"], r["published"]))
'
    printf '\n'
    printf 'Re-release one with the Release workflow, naming the package.\n\n'
fi

printf 'Bumps are resolved, built and DEP-8 tested every six hours, and land on master when they pass. Landing releases: the build, the tag and the archive ingest all follow from the commit.\n\n'
printf 'Checked by %s\n' "$run_url"
