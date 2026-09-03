#!/usr/bin/env bash
#
# Resolving a package's newest upstream release. Sourced, never run.
#
# Lifted verbatim from pkghaus/apt's watch-upstreams.sh, where these three
# functions have run every six hours since 2026-08-17. Duplicated rather than
# shared because a shell function cannot cross a repository boundary without a
# submodule or an action, and neither is worth it for fifty lines. If the
# archive's watcher and this ever disagree about what "newest" means, that is a
# bug in one of them.

# gh first (it carries its own auth), then a token from the environment,
# then anonymous. Anonymous works but shares a 60-requests-per-hour pool,
# which one full run very nearly exhausts.
#
# Three outcomes, not two, and keeping them apart is the point:
#
#   0   the body is on stdout
#   3   the resource is genuinely absent (HTTP 404)
#   1   could not ask -- network, auth, rate limit, 5xx
#
# Collapsing 3 and 1 into "no answer" is how a blip becomes a claim about
# upstream. latest_tag below falls back to the tag list on 3, because a project
# with no releases is a real and permanent state; on 1 it must refuse, because
# the tag list cannot be trusted to answer a question the releases endpoint was
# never asked.
#
# gh writes its error JSON to STDOUT and the message to stderr, then exits
# non-zero. Captured 2026-09-03 against a repo with no releases:
#
#   $ gh api repos/pb-/gotypist/releases/latest
#   {"message":"Not Found",...,"status":"404"}      <- stdout
#   gh: Not Found (HTTP 404)                        <- stderr, exit 1
#
# So the body is held and only printed on success. Passing gh's output straight
# through hands the caller an error document, and every `[ -n "$body" ]` check
# reads that as a result -- which is exactly how a survey of this fleet
# concluded that gotypist publishes releases.
#
# Note gh cannot tell "no releases" from "no such repository": both are 404
# with that identical message. Absent is absent; nothing here needs to care.
api() {
    local path="$1" body errfile rc status
    local -a auth=()

    if command -v gh >/dev/null 2>&1; then
        errfile="$(mktemp)"
        if body="$(gh api "$path" 2>"$errfile")"; then
            rm -f "$errfile"
            printf '%s' "$body"
            return 0
        fi
        rc=1
        if grep -q '(HTTP 404)' "$errfile"; then
            rc=3
        fi
        rm -f "$errfile"
        return "$rc"
    fi

    # An `if` rather than `[ ... ] && auth=(...)`: as a bare && list whose test
    # fails, that statement returns 1 and takes the whole run down under set -e.
    if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        auth=(-H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}")
    fi

    # No -f here on purpose: the status IS the answer, and -f discards it along
    # with the body. -w appends it, so one call yields both.
    body="$(curl -sS --connect-timeout 10 --max-time 30 \
        "${auth[@]}" -H "Accept: application/vnd.github+json" \
        -w '\n%{http_code}' "$API_BASE/$path" 2>/dev/null)" || return 1

    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    case "$status" in
        2??) printf '%s' "$body"; return 0 ;;
        404) return 3 ;;
        *)   return 1 ;;
    esac
}
# One field out of a JSON body, without requiring jq to be installed.
json_field() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$2 // empty"
    else
        sed -n "s/.*\"${1}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
    fi
}
# Every tag the remote has, one per line.
#
# git rather than the API: ls-remote has no pagination, so this cannot miss a
# newest tag that fell past page one. croc has 223 upstream tags against the
# 100 `tags?per_page=100` returned, and the API documents no ordering, so the
# old fallback sorted an arbitrary subset and took its maximum -- which can
# only under-report, never over-report, and therefore showed up as a package
# silently staying current rather than as an error.
#
# It also needs no token and does not consume the API rate limit, which one
# full fleet run very nearly exhausts anonymously.
#
# GIT_TERMINAL_PROMPT=0 because ls-remote against a private or absent
# repository asks for a username, and a prompt on a runner is a hung job
# rather than a failed one.
#
# The awk drops `^{}` peel lines -- the dereferenced commits of annotated
# tags, which would otherwise duplicate every annotated tag -- and strips the
# prefix. One awk rather than grep piped to sed, because grep exits 1 when it
# filters everything away, which turns a repository with no tags into a read
# failure under pipefail.
upstream_tags() {
    local repo="$1" refs
    refs="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags \
        "https://github.com/$repo" 2>/dev/null)" || return 1

    printf '%s\n' "$refs" | awk '
        $2 !~ /\^\{\}$/ { sub(/^refs\/tags\//, "", $2); if ($2 != "") print $2 }'
}

# The newest upstream tag. releases/latest is authoritative where it
# exists: it already excludes prereleases (lychee publishes a rolling
# "nightly" that would otherwise win) and it follows a project's own
# notion of a release, including workspace-prefixed schemes like
# lychee-v0.24.2. Projects that publish no releases at all (gotypist)
# fall back to the tag list, sorted properly rather than trusting the
# API's unspecified ordering.
latest_tag() {
    local repo="$1" body tag rc

    body="$(api "repos/$repo/releases/latest")" && rc=0 || rc=$?
    case "$rc" in
        0)
            tag="$(printf '%s' "$body" | json_field tag_name '.tag_name')"
            if [ -n "$tag" ]; then
                printf '%s\n' "$tag"
                return 0
            fi
            ;;
        3) ;;  # No releases published. Permanent, so the tag list is correct.
        *)
            # Could not ask. Refusing here is the whole point: the tag list
            # answers a different question, and one package in this fleet has
            # 223 upstream tags against a 100-per-page fallback.
            printf 'upstream: cannot reach releases/latest for %s\n' "$repo" >&2
            return 1
            ;;
    esac

    local tags
    tags="$(upstream_tags "$repo")" || {
        printf 'upstream: cannot read the tag list for %s\n' "$repo" >&2
        return 1
    }

    # Empty is not a read failure: a project with neither releases nor tags is
    # unresolvable, and saying so is different from saying the read broke.
    tag="$(printf '%s\n' "$tags" | sort -V | tail -n1)"
    if [ -n "$tag" ]; then
        printf '%s\n' "$tag"
        return 0
    fi
    return 1
}
