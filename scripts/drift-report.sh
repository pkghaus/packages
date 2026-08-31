#!/usr/bin/env bash
#
# Renders the drift dashboard body from a plan.
#
#   REPO=owner/name scripts/drift-report.sh <matrix-json> <verify-result> <run-url>
#
# One issue, rewritten each run, listing what is behind and where its pull
# request is. The pull request is the work; this is the index, and the only
# place a package whose verification failed becomes visible: no pull request
# opens for one, and a red run in a repository nobody watches notifies nobody.

# Two deliberate single-quotings that shellcheck reads as mistakes: the python3
# body must not be expanded by the shell, and the backticks in the markdown are
# code formatting rather than command substitution.
# shellcheck disable=SC2016

set -euo pipefail
shopt -s inherit_errexit

matrix="${1:?matrix json}"
verify="${2:?verify result}"
run_url="${3:?run url}"
REPO="${REPO:-}"

# One call, not one per package: 25 packages would otherwise be 25 API round
# trips to answer a question one listing answers.
open_prs=""
export OPEN_PRS=""
if [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
    open_prs="$(gh pr list --repo "$REPO" --state open --json headRefName,url \
                  --jq '.[] | "\(.headRefName)\t\(.url)"' 2>/dev/null || true)"
    export OPEN_PRS="$open_prs"
fi

# python3, not sed: splitting JSON on "},{" is fragile and quietly dropped
# every row but the first when it was tried.
printf '%s' "$matrix" | python3 -c '
import json, sys, os
prs = {}
for line in os.environ.get("OPEN_PRS", "").splitlines():
    if "\t" in line:
        branch, url = line.split("\t", 1)
        prs.setdefault(branch.rsplit("/", 1)[0] + "/", url)
rows = json.load(sys.stdin)
print("| package | upstream tag | pull request |")
print("|---|---|---|")
for e in rows:
    pkg, tag = e["package"], e["tag"]
    url = prs.get(f"bump/{pkg}/", "none yet")
    print(f"| `{pkg}` | `{tag}` | {url} |")
'

printf '\n'
# failure or cancelled only. "skipped" is the normal state on a merge, where the
# dashboard is re-rendered and nothing is meant to be built: warning there would
# put "verification did not pass" on the issue after every successful merge.
case "$verify" in
    failure|cancelled)
        printf '**Verification did not pass for every package in this run** (`%s`). A package whose build or DEP-8 tests fail never gets a pull request, so a row above with no link may be waiting on a packaging change rather than on a merge.\n\n' "$verify"
        ;;
esac
printf 'Bumps are opened automatically and verified before they are opened. Merging one releases it: the build, the tag and the archive ingest all follow from the merge.\n\n'
printf 'Checked by %s\n' "$run_url"
