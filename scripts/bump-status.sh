#!/usr/bin/env bash
#
#   bump-status.sh <matrix-json> < jobs-json
#
# Emits "<package>\t<verify>\t<land>" per planned package, from the conclusions
# of the verify and land legs in a workflow run. jobs-json is what
# `gh api repos/OWNER/REPO/actions/runs/<id>/jobs` returns.
#
# Two columns because two jobs can stop a bump and they stop it differently.
# verify builds and DEP-8 tests the bump; land writes the commit that releases
# it. A package can pass all three suites and still not reach master -- a
# signed-commit call rejected on a stale expectedHeadOid, a GitHub API outage --
# and until 2026-09-04 nothing said so. Only the verify legs were read, so a
# package that verified green reported success whether or not its commit
# existed, and the dashboard's whole purpose is to make that kind of silence
# impossible.
#
# The land column is NOT a second opinion on verify. A land job runs for every
# planned package whatever verify concluded, and its gate step exits 0 after
# refusing to land an unverified one, so a land leg concluding "success" means
# "the job did not error", never "the package landed". Read it only once verify
# has already said success. drift-report.sh does; the land job's own gate reads
# column 2 alone, which it must -- at that moment its package's land leg is the
# job asking the question, and is in_progress by construction.
#
# The dashboard used to say only "verification did not pass for every package in
# this run", once, for the whole run. You could still work out which package it
# meant, because a failed package got no pull request and its row's link column
# was empty -- the column was doing double duty as a per-package status by
# accident. Stage 2 removed pull requests, and with them that accident, so the
# status has to be stated rather than inferred.
#
# A verify leg is named "<package> <tag> / <suite>" and a land leg "land
# <package>". They are told apart by the " / ", checked first, rather than by
# the "land " prefix: `land` is a legal Debian source name, and that package's
# own verify legs would otherwise be filed as a land leg belonging to its tag.
#
# A package with no matching leg is "unknown", never "success". A reporter that
# says nothing went wrong because it could not find anything is worse than no
# reporter: it is the same output as a clean run.

set -euo pipefail
shopt -s inherit_errexit

matrix="${1:?usage: bump-status.sh <matrix-json> < jobs-json}"

MATRIX="$matrix" python3 -c '
import json, os, sys

planned = [e["package"] for e in json.loads(os.environ["MATRIX"])]
# gh api --paginate --slurp returns a list of response objects, one per page;
# a single call returns the object itself. A bump run is 1 + packages*7 + 1
# jobs -- verify is three suites by two architectures, plus one land each -- so
# a full fleet behind at once is 177, well past a page.
raw = json.load(sys.stdin)
pages = raw if isinstance(raw, list) else [raw]
jobs = [j for page in pages for j in page.get("jobs", [])]

verify, land = {}, {}
for j in jobs:
    name = j.get("name", "")
    outcome = j.get("conclusion") or j.get("status") or "unknown"
    # " / " first. Anything with neither marker is a different job in the same
    # run -- plan, report -- and is not a leg of either kind.
    if " / " in name:
        pkg = name.split(" ", 1)[0]
        if pkg in planned:
            verify.setdefault(pkg, []).append(outcome)
    elif name.startswith("land "):
        pkg = name[len("land "):]
        if pkg in planned:
            land.setdefault(pkg, []).append(outcome)

def verdict(got):
    if not got:
        return "unknown"
    if any(c == "failure" for c in got):
        return "failure"
    if any(c == "cancelled" for c in got):
        return "cancelled"
    if all(c == "success" for c in got):
        return "success"
    # in_progress, skipped, anything new GitHub grows: name it rather than
    # rounding it to success.
    return sorted(set(got))[0]

for pkg in planned:
    print("%s\t%s\t%s" % (pkg, verdict(verify.get(pkg)), verdict(land.get(pkg))))
'
