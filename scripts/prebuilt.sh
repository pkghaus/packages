#!/usr/bin/env bash
#
# Can the release gate be skipped because this exact tree was already built?
#
#   scripts/prebuilt.sh <merge-sha> <planned-packages-json>   -> true|false on stdout
#
# A merge-driven release currently rebuilds a tree the pull request already
# built minutes earlier, across every suite and architecture, through the same
# reusable workflow with the same inputs. Measured over the last 30 release
# runs: 16 were pull-request merges and they spent 241 minutes between them
# proving what was already proven.
#
# The bot path does not pay this -- bump.yml builds once, lands through the
# API (a GITHUB_TOKEN push starts no workflow run) and dispatches with
# skip_build. A hand dispatch must always pay it, because nothing else may have
# built at all. This covers only the third case, the push.
#
# THE DEFAULT IS TO BUILD. Every question this cannot answer answers "false":
# a missing pull request, an API shape that changed, an empty field, a run that
# cannot be found. Skipping wrongly tags a tree nobody compiled; building
# wrongly costs 824 seconds. The asymmetry decides every branch below.

set -euo pipefail

die() { echo "prebuilt: $*" >&2; exit 1; }

# The decision, separated from the fetching so it can be tested without a
# network. Every argument is a fact gathered above it; this function does no
# lookups and has no opinions beyond comparing them.
#
#   merge_tree   tree of the commit being released
#   pr_tree      tree of the pull request head that CI built
#   conclusion   that run's conclusion, verbatim from the API
#   built_ref    the builder the run resolved, from referenced_workflows
#   want_ref     the builder a run today would resolve
#   built_pkgs   newline-separated packages that run built
#   want_pkgs    newline-separated packages this release plans
prebuilt_verdict() {
    local merge_tree="${1-}" pr_tree="${2-}" conclusion="${3-}"
    local built_ref="${4-}" want_ref="${5-}" built_pkgs="${6-}" want_pkgs="${7-}"
    local pkg

    # An empty anything means a lookup did not answer. Not an error: the caller
    # may legitimately have no pull request, which is simply not skippable.
    [ -n "$merge_tree" ] && [ -n "$pr_tree" ] || { echo false; return 0; }
    [ -n "$built_ref" ] && [ -n "$want_ref" ] || { echo false; return 0; }
    [ -n "$want_pkgs" ] || { echo false; return 0; }

    # The tree is the whole input to a build, so equal trees mean the same
    # build -- given the same builder, which is the next check.
    [ "$merge_tree" = "$pr_tree" ] || { echo false; return 0; }

    # Merging does not require green checks here: the ruleset carries
    # required_signatures and deletion, not required status checks, so a red
    # pull request can be merged and its run's conclusion is the only thing
    # that knows.
    [ "$conclusion" = "success" ] || { echo false; return 0; }

    # build.yml is called as @v1, a FLOATING tag. A pull request built while v1
    # pointed at one commit and merged after it moved was gated by a different
    # builder, and equal package trees say nothing about that. referenced_workflows
    # records the tag object the run resolved, which changes whenever v1 moves.
    [ "$built_ref" = "$want_ref" ] || { echo false; return 0; }

    # Every package this release plans must be one that run built. The subset
    # holds by construction -- a changelog change is a directory touch, and
    # build.yml plans by touched directory -- but "by construction" is what the
    # mtime survey thought about install routes, so it is checked.
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        printf '%s\n' "$built_pkgs" | grep -qxF "$pkg" || { echo false; return 0; }
    done <<< "$want_pkgs"

    echo true
}

# Gathers the facts and prints the verdict. Any failure here is caught and
# turned into "false" rather than a non-zero exit: a release must not fail
# because an optimisation could not make up its mind.
main() {
    local merge_sha="${1:?usage: $0 <merge-sha> <planned-packages-json>}"
    local planned="${2:?}"
    local repo="${GITHUB_REPOSITORY:?}"
    local builder_repo="${BUILDER_REPO:-pkghaus/action-debian-build}"

    local pr_head merge_tree pr_tree run conclusion built_ref want_ref
    local built_pkgs want_pkgs

    want_pkgs="$(printf '%s' "$planned" | jq -r '.[].package' 2>/dev/null || true)"

    pr_head="$(gh api "repos/$repo/commits/$merge_sha/pulls" \
        --jq '.[0].head.sha // empty' 2>/dev/null || true)"
    [ -n "$pr_head" ] || { echo false; return 0; }

    merge_tree="$(gh api "repos/$repo/git/commits/$merge_sha" --jq '.tree.sha // empty' 2>/dev/null || true)"
    pr_tree="$(gh api "repos/$repo/git/commits/$pr_head" --jq '.tree.sha // empty' 2>/dev/null || true)"

    # The pull request's own build run, found by head sha rather than by
    # number: a pull request can have several runs and only the one for this
    # exact commit says anything about this exact tree.
    run="$(gh api "repos/$repo/actions/workflows/build.yml/runs?head_sha=$pr_head&per_page=1" \
        --jq '.workflow_runs[0].id // empty' 2>/dev/null || true)"
    [ -n "$run" ] || { echo false; return 0; }

    conclusion="$(gh api "repos/$repo/actions/runs/$run" --jq '.conclusion // empty' 2>/dev/null || true)"
    built_ref="$(gh api "repos/$repo/actions/runs/$run" \
        --jq '[.referenced_workflows[]? | select(.path | startswith("'"$builder_repo"'/.github/workflows/build.yml")) | .sha] | first // empty' \
        2>/dev/null || true)"

    # What a run started now would resolve v1 to. The tag object, not the
    # commit: that is what referenced_workflows reports.
    want_ref="$(gh api "repos/$builder_repo/git/ref/tags/v1" --jq '.object.sha // empty' 2>/dev/null || true)"

    # The jobs that actually built, by the matrix name build.yml gives them.
    #
    # --paginate is not optional. One release wave ran 138 legs plus a plan
    # job, and a single page holds 100: without it every package past the
    # hundredth reads as unbuilt, the verdict is false, and the gate runs --
    # safe, but silently never skipping on exactly the waves worth skipping.
    built_pkgs="$(gh api --paginate "repos/$repo/actions/runs/$run/jobs?per_page=100" \
        --jq '[.jobs[] | select(.conclusion == "success") | .name | split(" /")[0]] | unique | .[]' \
        2>/dev/null || true)"

    prebuilt_verdict "$merge_tree" "$pr_tree" "$conclusion" \
        "$built_ref" "$want_ref" "$built_pkgs" "$want_pkgs"
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

main "$@"
