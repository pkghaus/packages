#!/usr/bin/env bash
#
#   check-keyring-author.sh <from> <to>
#
# Fails if any commit in the range touches pkghaus-archive-keyring/ and was
# authored by a bot.
#
# That directory ships the public half of the archive signing key: it is what
# apt uses to verify every other package here, so it is the one thing in this
# repository whose compromise escalates. Change the shipped key and a later
# archive, signed with the genuine key, hands every client an attacker's
# keyring.
#
# Two conventions already keep the automation out of it -- plan-bumps.sh skips
# a native package, and the signed-commit step's pathspec names only the bumped
# package's two files. Both live inside the workflow they constrain, so both
# fail open if that workflow is wrong. This check does not: it runs afterwards,
# reads what actually landed, and answers from the commit rather than from the
# process that made it.
#
# Detective, not preventive. It cannot stop the write, only refuse to let it
# pass silently -- which is the difference between finding out now and finding
# out when a user reports a bad signature.

set -euo pipefail
shopt -s inherit_errexit

GUARDED="${GUARDED:-pkghaus-archive-keyring/}"
ROOT="${ROOT:-.}"

from="${1:?usage: check-keyring-author.sh <from> <to>}"
to="${2:?usage: check-keyring-author.sh <from> <to>}"

git_() { git -C "$ROOT" "$@"; }

bad=0
while read -r commit; do
    [ -n "$commit" ] || continue
    # --format= empties the header so only the file list remains.
    files="$(git_ show --name-only --format= "$commit")"
    case "$files" in *"$GUARDED"*) ;; *) continue ;; esac

    # The author's NAME, not the email. A bot's email ends in
    # users.noreply.github.com, and so does a person's when they have email
    # privacy on, so the email cannot tell them apart. GitHub renders every app
    # identity with a literal [bot] suffix on the name.
    author="$(git_ show -s --format='%an' "$commit")"
    case "$author" in
        *'[bot]'*)
            printf '%s touched %s, authored by %s\n' "$commit" "$GUARDED" "$author" >&2
            bad=$((bad + 1))
            ;;
    esac
done < <(git_ rev-list "$from..$to")

if [ "$bad" -gt 0 ]; then
    printf 'REFUSED: %d bot-authored commit(s) touched %s\n' "$bad" "$GUARDED" >&2
    exit 1
fi
printf 'ok: no bot-authored commit touched %s\n' "$GUARDED"
