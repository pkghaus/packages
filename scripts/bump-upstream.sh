#!/usr/bin/env bash
#
# Prepares one packaging repo for a new upstream release: rewrites
# package.conf's VERSION and prepends a debian/changelog entry.
#
#   scripts/bump-upstream.sh <checkout-dir> <upstream-tag>
#
# Local file edits only. No network, no git, no PR -- the workflow around it
# does those. Keeping the part that decides what a version becomes free of
# both means it can be tested offline against the fleet's real version
# strings, which is where this is most likely to be wrong.
#
# Exit: 0 edited, 3 already current, 4 refused.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

die() { printf 'bump: %s\n' "$1" >&2; exit 4; }

# The upstream tag is not the Debian upstream version. Measured across the
# fleet: lychee-v0.24.2 -> 0.24.2, v1.0.5.2 -> 1.0.5.2, while 39.2.0 and
# 2.13.c.5 are already bare. Stripping the leading run of non-digits covers
# every scheme in the fleet without a per-package table, because every one of
# them prefixes rather than infixes.
upstream_version() {
    printf '%s\n' "${1#"${1%%[0-9]*}"}"
}

# A native package is its own upstream: archive-keyring's version tracks the
# signing key, not a release feed. Bumping it from a tag lookup is meaningless,
# so it is refused rather than skipped silently.
is_native() {
    case "$(cat "$1/debian/source/format" 2>/dev/null)" in
        *native*) return 0 ;;
        *) return 1 ;;
    esac
}

# Source name and full version from the changelog's first line, which is the
# authority for both -- package.conf carries the upstream tag, not the Debian
# version.
changelog_head() { sed -n '1s/^\([^ ]*\) (\([^)]*\)).*/\1 \2/p' "$1/debian/changelog"; }

bump() {
    local dir="$1" tag="$2"
    [ -d "$dir" ] || die "no such directory: $dir"
    [ -f "$dir/package.conf" ] || die "no package.conf in $dir"
    [ -f "$dir/debian/changelog" ] || die "no debian/changelog in $dir"
    is_native "$dir" && die "native package: its version is not an upstream tag"

    # The tag is upstream's string, fetched from their API, and it reaches sed's
    # replacement below where '&' means "the whole match" -- a tag containing
    # one rewrites package.conf into garbage rather than failing. Every tag in
    # the fleet fits this charset; anything outside it is refused rather than
    # escaped, because a tag needing escaping is a packaging decision.
    case "$tag" in
        ''|*[!A-Za-z0-9._+-]*) die "tag [$tag] is not a plain version tag" ;;
    esac

    local new_upstream head source current current_upstream
    new_upstream="$(upstream_version "$tag")"
    [ -n "$new_upstream" ] || die "tag [$tag] yields no version"

    head="$(changelog_head "$dir")"
    source="${head%% *}"
    current="${head##* }"
    current_upstream="${current%-*}"
    [ -n "$source" ] && [ -n "$current" ] || die "cannot parse debian/changelog"

    # An epoch has no counterpart in an upstream tag, so a new version derived
    # from one would silently drop it and read as a downgrade to every apt
    # client. The version comparison below would refuse it anyway; refusing here
    # says why. No fleet package carries one today.
    case "$current" in
        *:*) die "$source carries an epoch ($current); bump it by hand" ;;
    esac

    if [ "$new_upstream" = "$current_upstream" ]; then
        printf 'bump: %s is already at %s\n' "$source" "$current_upstream" >&2
        exit 3
    fi

    # A newest-tag lookup that falls back to sorting can pick something older
    # than what is packaged, and an automated downgrade is the one mistake here
    # that a reviewer skimming a two-line diff would not catch. dpkg orders the
    # fleet's odd schemes correctly; where it is absent the check is skipped
    # rather than guessed at.
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --compare-versions "$new_upstream" gt "$current_upstream" \
            || die "refusing to move $source from $current_upstream to $new_upstream"
    fi

    # A new upstream version restarts the Debian revision.
    local new_version="$new_upstream-1"

    sed -i "s|^VERSION=.*|VERSION=$tag|" "$dir/package.conf"
    grep -q "^VERSION=$tag$" "$dir/package.conf" || die "package.conf VERSION did not take"

    # Written as a group rather than through a command substitution: $(...)
    # strips trailing newlines, which silently welded the new trailer onto the
    # previous entry's first line and produced an unparseable changelog.
    {
        printf '%s (%s) unstable; urgency=medium\n\n  * New upstream release\n\n -- pkg.haus archive <archive@pkg.haus>  %s\n\n' \
            "$source" "$new_version" "$(date -R)"
        cat "$dir/debian/changelog"
    } > "$dir/debian/changelog.new"
    mv "$dir/debian/changelog.new" "$dir/debian/changelog"

    # Make the tree consistent with the timestamp just written into it.
    #
    # dpkg-source clamps an mtime NEWER than SOURCE_DATE_EPOCH down to it and
    # PRESERVES an older one, so a file older than the changelog entry keeps its
    # own checkout mtime and that leg's source package stops matching the
    # others'. action-debian-build refuses the build for exactly that.
    #
    # A bump is where it becomes a coin flip. The checkout gives every file a
    # sub-second mtime, say 04:21:32.4, and `date -R` truncates the entry to
    # whole seconds. Land in the same second and the epoch is 04:21:32.0: the
    # files are newer, dpkg-source clamps them all to one value, the build
    # passes. Cross into the next second and the epoch is 04:21:33.0, every file
    # predates it, and the build fails. Measured at about one run in sixty, and
    # on 2026-09-03 it took one leg of vale's three while the other two, stamped
    # one second earlier, passed (run 33714720341).
    #
    # Explicitly epoch+1 rather than "now": "now" is only *probably* later than
    # an epoch truncated downwards, which is the same coin flip one notch
    # smaller. Everything then clamps to the epoch and every leg agrees.
    local stamp
    stamp="$(cd "$dir" && dpkg-parsechangelog -l debian/changelog -S Timestamp)"
    find "$dir" -exec touch -d "@$((stamp + 1))" {} +

    printf '%s %s -> %s\n' "$source" "$current" "$new_version"
}

# Sourceable for tests: everything above is definitions, everything below runs.
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

[ $# -eq 2 ] || { printf 'usage: %s <checkout-dir> <upstream-tag>\n' "$0" >&2; exit 4; }
bump "$1" "$2"
