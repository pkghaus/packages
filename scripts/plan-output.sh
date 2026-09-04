#!/usr/bin/env bash
#
# Print the two step outputs every plan in this repository produces.
#
#   scripts/plan-output.sh <json-array> [name] >> "$GITHUB_OUTPUT"
#
#   <name>=<json-array>
#   has_work=true|false
#
# <name> defaults to "matrix"; build.yml's plan calls its output "packages".
#
# Written out four times before this -- build.yml, bump.yml, and twice inside
# release.yml's plan step, which grew a dispatch path beside its push path and
# copied the block rather than sharing it. Each copy re-derived the same count
# and re-set the same boolean, and only one of the four carried the note
# explaining why it is a boolean at all.
#
# That note is the reason this is worth a file. has_work is a string "true" or
# "false", never a count the caller compares: a step output that never got set
# comes back as the empty string, and in a GitHub expression `'' != '0'` is
# TRUE. A plan that failed before writing its output would therefore start the
# matrix job with no vectors, and a matrix with no vectors is a failed run
# rather than a skipped one. Comparing against a count is the shape that breaks;
# asking for an explicit "true" is the shape that does not.
#
# It prints rather than writing $GITHUB_OUTPUT so the decision stays testable
# outside a runner; the caller does the appending.

set -euo pipefail
shopt -s inherit_errexit

json="${1?usage: plan-output.sh <json-array> [name]}"
name="${2:-matrix}"

# Counted by parsing, not by grepping for a key. bump.yml used to count
# occurrences of the string "package", which is right only for its own row
# shape and silently wrong for build.yml's array of plain strings.
count="$(printf '%s' "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

has_work=false
if [ "$count" -gt 0 ]; then
    has_work=true
fi

printf '%s=%s\n' "$name" "$json"
printf 'has_work=%s\n' "$has_work"
