#!/usr/bin/env bash
#
# Emits the release work as a JSON array, for a workflow matrix:
#
#   [{"package":"croc","version":"11.3.6-1","tag":"croc/v11.3.6-1"}]
#
# Reads changed paths on stdin, keeps the packages whose debian/changelog moved,
# and drops the ones already tagged.
#
# The changelog and not package.conf, because the tag carries the Debian
# revision and that is the only file it exists in. A packaging-only fix -- a
# build dependency, a lintian override, a new revision of the same upstream --
# releases on exactly the same path as an upstream bump, which is what stops
# those from needing a second mechanism.
#
# The tag is the idempotency key for the whole release path. A re-run, a
# changelog edit that does not change the version, and a tag someone pushed by
# hand all converge here on "nothing to do" rather than on a second release.

set -euo pipefail
shopt -s inherit_errexit

ROOT="${ROOT:-.}"

die() { printf '%s\n' "$*" >&2; exit 1; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# The same first-line parse bump-upstream.sh writes, narrowed to the version.
changelog_version() {
    sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p' "$ROOT/$1/debian/changelog"
}

# Overridden in the tests. Local refs, which is only trustworthy because the
# workflow checks out with fetch-depth 0; a shallow clone carries no tags and
# every package would look unreleased.
tag_exists() {
    git -C "$ROOT" rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1
}

plan() {
    local rows="" seen=" " path pkg version tag
    while read -r path; do
        pkg="${path%%/*}"
        # Exact, not a glob: '*/debian/changelog' would also accept
        # a/b/debian/changelog and silently name the package 'a'.
        [ "$path" = "$pkg/debian/changelog" ] || continue
        # A directory that is not a package cannot be released. Staged packages
        # are deliberately included -- enrolment gates publishing, and the
        # archive drops what packages.txt does not list.
        [ -f "$ROOT/$pkg/package.conf" ] || continue
        case "$seen" in *" $pkg "*) continue ;; esac
        seen="$seen$pkg "

        version="$(changelog_version "$pkg")"
        [ -n "$version" ] || die "cannot parse $pkg/debian/changelog"

        # An epoch's colon and a tilde are both illegal in a ref name. Loud
        # rather than skipped: a package that silently stops releasing looks
        # exactly like a package with nothing to release.
        case "$version" in
            *[:~^\ ]*|*..*) die "$pkg $version cannot be a tag name" ;;
        esac

        tag="$pkg/v$version"
        if tag_exists "$tag"; then
            printf 'SKIP %s: %s already exists\n' "$pkg" "$tag" >&2
            continue
        fi

        rows="$rows,{\"package\":\"$(json_escape "$pkg")\""
        rows="$rows,\"version\":\"$(json_escape "$version")\""
        rows="$rows,\"tag\":\"$(json_escape "$tag")\"}"
    done

    printf '[%s]\n' "${rows#,}"
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

plan
