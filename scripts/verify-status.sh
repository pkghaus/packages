#!/usr/bin/env bash
#
#   verify-status.sh <matrix-json> < jobs-json
#
# Emits "<package>\t<status>" per planned package, from the conclusions of the
# verify legs in a workflow run. jobs-json is what
# `gh api repos/OWNER/REPO/actions/runs/<id>/jobs` returns.
#
# The dashboard used to say only "verification did not pass for every package in
# this run", once, for the whole run. You could still work out which package it
# meant, because a failed package got no pull request and its row's link column
# was empty -- the column was doing double duty as a per-package status by
# accident. Stage 2 removes pull requests, and with them that accident, so the
# status has to be stated rather than inferred.
#
# The verify job names its legs "<package> <tag> / <suite>". A Debian source
# name cannot contain a space, so the first token is the package.
#
# A package with no matching leg is "unknown", never "success". A reporter that
# says nothing went wrong because it could not find anything is worse than no
# reporter: it is the same output as a clean run.

set -euo pipefail
shopt -s inherit_errexit

matrix="${1:?usage: verify-status.sh <matrix-json> < jobs-json}"

MATRIX="$matrix" python3 -c '
import json, os, sys

planned = [e["package"] for e in json.loads(os.environ["MATRIX"])]
# gh api --paginate --slurp returns a list of response objects, one per page;
# a single call returns the object itself. A bump run is 1 + packages*3 + 2
# jobs, so 33 packages behind at once would silently lose a page.
raw = json.load(sys.stdin)
pages = raw if isinstance(raw, list) else [raw]
jobs = [j for page in pages for j in page.get("jobs", [])]

legs = {}
for j in jobs:
    name = j.get("name", "")
    # "<package> <tag> / <suite>". Anything without a space is a different job
    # in the same run -- plan, report, open -- and is not a verify leg.
    if " " not in name:
        continue
    pkg = name.split(" ", 1)[0]
    if pkg not in planned:
        continue
    legs.setdefault(pkg, []).append(j.get("conclusion") or j.get("status") or "unknown")

for pkg in planned:
    got = legs.get(pkg)
    if not got:
        status = "unknown"
    elif any(c == "failure" for c in got):
        status = "failure"
    elif any(c == "cancelled" for c in got):
        status = "cancelled"
    elif all(c == "success" for c in got):
        status = "success"
    else:
        # in_progress, skipped, anything new GitHub grows: name it rather than
        # rounding it to success.
        status = sorted(set(got))[0]
    print("%s\t%s" % (pkg, status))
'
