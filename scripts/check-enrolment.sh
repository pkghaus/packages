#!/usr/bin/env bash
#
# Asserts that every enrolled package exists in the tree.
#
#   scripts/check-enrolment.sh
#
# One-directional on purpose. An enrolled line with no directory is an error:
# the ingest would try to build a package that is not here. A directory with no
# line is NOT an error: that is a package staged in the tree, getting its pull
# requests built, deliberately not published yet.

set -euo pipefail
shopt -s inherit_errexit

PACKAGES_FILE="${PACKAGES_FILE:-packages.txt}"
ROOT="${ROOT:-.}"

missing=0
enrolled=0
while read -r pkg; do
    case "$pkg" in ''|\#*) continue ;; esac
    pkg="${pkg%%[[:space:]]*}"
    enrolled=$((enrolled + 1))
    if [ ! -f "$ROOT/$pkg/package.conf" ]; then
        printf 'enrolled but absent: %s (no %s/package.conf)\n' "$pkg" "$pkg" >&2
        missing=$((missing + 1))
    fi
done < "$PACKAGES_FILE"

staged=0
for d in "$ROOT"/*/; do
    d="${d%/}"; name="${d##*/}"
    [ -f "$d/package.conf" ] || continue
    grep -qx "$name" "$PACKAGES_FILE" || { staged=$((staged + 1)); printf 'staged, not enrolled: %s\n' "$name"; }
done

printf '%s enrolled, %s staged, %s missing\n' "$enrolled" "$staged" "$missing"
[ "$missing" -eq 0 ]
