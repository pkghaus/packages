#!/usr/bin/env bash
#
# Renders the drift dashboard body, or nothing at all when nothing is wrong.
#
#   scripts/drift-report.sh <matrix-json> <status-tsv> <stuck-json> <run-url> [verified]
#
# The dashboard is a problem list, not a work log. It names bumps that did not
# land and packages whose changelog the archive does not serve. A bump that
# built, tested, landed and published leaves nothing here: the commit, the tag,
# the release run and the archive already carry it.
#
# It used to render one row per planned package whatever the outcome, including
# "landed, releasing" for the ones that had just worked. That row was written by
# the very run that made it obsolete -- the plan is taken before anything lands
# -- and nothing could retract it, because a run whose plan found work can never
# satisfy its own close condition, and the push trigger that used to re-render
# on a landing stopped firing when landing became a GITHUB_TOKEN commit. So a
# successful croc bump left an issue standing for hours saying croc was behind,
# which is how a notifying surface teaches its reader to stop opening it.
#
# EMPTY OUTPUT IS THE ANSWER "nothing to report". The caller decides between
# writing the issue and closing it on that and nothing else, so the judgement is
# made once, here, instead of being reconstructed from the same inputs twice.
#
# <verified> is "no" for a run that verified nothing -- a push, where verify and
# land are skipped by design. Such a run holds no verdict on any package, and
# asking for one reads every planned package as "not verified", which is a false
# alarm rather than a missing job. It renders the published check alone.
#
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
verified="${5:-yes}"

export STATUS_TSV="$status_tsv"

bumps=""
if [ "$verified" = yes ]; then
    bumps="$(printf '%s' "$matrix" | python3 -c '
import json, sys, os

# "<package>\t<verify>\t<land>" from bump-status.sh. A package missing from it,
# or a line short of its land column, is unknown rather than fine: see the note
# there.
status = {}
for line in os.environ.get("STATUS_TSV", "").splitlines():
    parts = line.split("\t")
    if len(parts) >= 2:
        status[parts[0]] = (parts[1].strip(),
                            parts[2].strip() if len(parts) > 2 else "unknown")

# What the reader needs to do about it, not what the runner called it. Two maps,
# because the two jobs fail differently and so does the fix: a verification
# failure belongs to the package and waits for upstream or for packaging work,
# a landing failure belongs to the pipeline and usually clears on the next run.
# Neither map has an entry for "success" on purpose.
#
# No apostrophes below this line. The whole python program is a single-quoted
# shell argument, so one would end it and hand bash the rest as syntax.
VERIFY = {
    "failure":   "**verification failed**",
    "cancelled": "**verification cancelled**",
    "unknown":   "**not verified**",
}
LAND = {
    "failure":   "**verified, but landing failed**",
    "cancelled": "**verified, but landing was cancelled**",
    "unknown":   "**verified, but landing is unaccounted for**",
}

# None means the bump landed, which is not a problem and gets no row. The land
# column is consulted only after verify has said success: a land leg runs for
# every planned package and exits 0 after refusing to land an unverified one, so
# on its own "success" there means the job did not error, not that anything
# reached master.
def verdict(pkg):
    v, l = status.get(pkg, ("unknown", "unknown"))
    if v != "success":
        return VERIFY.get(v) or ("**verification " + v + "**")
    if l == "success":
        return None
    return LAND.get(l) or ("**landing " + l + "**")

rows = [(e, verdict(e["package"])) for e in json.load(sys.stdin)]
rows = [(e, word) for e, word in rows if word is not None]
if rows:
    print("### Bumps that did not land")
    print()
    print("| package | upstream tag | status |")
    print("|---|---|---|")
    for e, word in rows:
        print("| `%s` | `%s` | %s |" % (e["package"], e["tag"], word))
')"
fi

published=""
if [ "$stuck" != "[]" ] && [ -n "$stuck" ]; then
    published="$(printf '%s' "$stuck" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print("### Packaged but not published")
print()
print("These carry a `debian/changelog` version the archive does not serve, with no release or ingest running. Usually a release or a publish that failed after the changelog landed; nothing retries either, and the drift check reports them current because package.conf matches upstream.")
print()
print("| package | arch | packaged | published |")
print("|---|---|---|---|")
for r in rows:
    print("| `%s` | %s | `%s` | `%s` |"
          % (r["package"], r["arch"], r["packaged"], r["published"]))
print()
print("Re-release one with the Release workflow, naming the package.")
')"
fi

# Nothing to say. Not an empty issue body, no output at all: the caller reads
# that as "close it", and an issue that exists only to report that it has
# nothing to report is the surface this change removes.
if [ -z "$bumps" ] && [ -z "$published" ]; then
    exit 0
fi

[ -z "$bumps" ]     || printf '%s\n\n' "$bumps"
[ -z "$published" ] || printf '%s\n\n' "$published"

printf 'Bumps are resolved, built and DEP-8 tested every six hours, and land on master when they pass. Landing releases: the build, the tag and the archive ingest all follow from the commit. A package that lands and publishes cleanly is never listed here.\n\n'
printf 'Checked by %s\n' "$run_url"
