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
api() {
    local path="$1"
    if command -v gh >/dev/null 2>&1; then
        gh api "$path" 2>/dev/null
    elif [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        curl -fsS --connect-timeout 10 --max-time 30 \
            -H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" "$API_BASE/$path" 2>/dev/null
    else
        curl -fsS --connect-timeout 10 --max-time 30 \
            -H "Accept: application/vnd.github+json" \
            "$API_BASE/$path" 2>/dev/null
    fi
}
# One field out of a JSON body, without requiring jq to be installed.
json_field() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$2 // empty"
    else
        sed -n "s/.*\"${1}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
    fi
}
# The newest upstream tag. releases/latest is authoritative where it
# exists: it already excludes prereleases (lychee publishes a rolling
# "nightly" that would otherwise win) and it follows a project's own
# notion of a release, including workspace-prefixed schemes like
# lychee-v0.24.2. Projects that publish no releases at all (gotypist)
# fall back to the tag list, sorted properly rather than trusting the
# API's unspecified ordering.
latest_tag() {
    local repo="$1" body tag
    if body="$(api "repos/$repo/releases/latest")" && [ -n "$body" ]; then
        tag="$(printf '%s' "$body" | json_field tag_name '.tag_name')"
        if [ -n "$tag" ]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi
    if body="$(api "repos/$repo/tags?per_page=100")" && [ -n "$body" ]; then
        if command -v jq >/dev/null 2>&1; then
            tag="$(printf '%s' "$body" | jq -r '.[].name' | sort -V | tail -n1)"
        else
            tag="$(printf '%s' "$body" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sort -V | tail -n1)"
        fi
        [ -n "$tag" ] && { printf '%s\n' "$tag"; return 0; }
    fi
    return 1
}
