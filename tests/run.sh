#!/usr/bin/env bash
#
# The bump's decisions that are dangerous to get wrong and quiet when they are:
# what an upstream tag becomes as a Debian version, and what it refuses.
#
#   tests/run.sh
#
# Three habits of this file that shellcheck reads as mistakes, all deliberate.
# Each group runs in a subshell so its environment cannot leak into the next,
# hence the subshell-local assignment warnings. The fixtures are reached only
# through functions sourced from the script under test, which static analysis
# cannot follow. And the backticks in the expected markdown are code formatting,
# not command substitution.
# shellcheck disable=SC2016,SC2030,SC2031,SC2317,SC2329

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n    %s\n' "$1" "$2"; fail=$((fail + 1)); }

eq() { # label expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$3] want [$2]"; fi
}

echo "upstream bump"
(
    # shellcheck source=scripts/bump-upstream.sh
    . "$ROOT/scripts/bump-upstream.sh"

    # The fleet's tag schemes, verbatim. Every one of these is a real string
    # from a real package.conf; the mapping is what decides the Debian version.
    eq "a bare version is left alone"          "39.2.0"    "$(upstream_version 39.2.0)"
    eq "a letter inside a version survives"    "2.13.c.5"  "$(upstream_version 2.13.c.5)"
    eq "a leading v is stripped"               "1.0.5.2"   "$(upstream_version v1.0.5.2)"
    eq "a workspace prefix is stripped"        "0.24.2"    "$(upstream_version lychee-v0.24.2)"
    eq "a date-shaped version survives"        "2026.08.15" "$(upstream_version v2026.08.15)"

    work="$(mktemp -d)"
    make_pkg() { # dir source version format
        mkdir -p "$1/debian/source"
        printf '%s\n' "$4" > "$1/debian/source/format"
        printf 'UPSTREAM=https://github.com/x/y.git\nVERSION=v%s\n' "$3" > "$1/package.conf"
        printf '%s (%s-1) unstable; urgency=medium\n\n  * Previous\n\n -- pkg.haus archive <archive@pkg.haus>  Mon, 01 Jan 2001 00:00:00 +0000\n' \
            "$2" "$3" > "$1/debian/changelog"
    }

    make_pkg "$work/a" demo 1.0.0 "3.0 (quilt)"
    ( bump "$work/a" v1.1.0 >/dev/null 2>&1 )
    eq "package.conf takes the tag verbatim, not the stripped version" \
       "VERSION=v1.1.0" "$(grep '^VERSION=' "$work/a/package.conf")"
    eq "a new upstream version restarts the revision at 1" \
       "demo (1.1.0-1) unstable; urgency=medium" "$(head -1 "$work/a/debian/changelog")"

    # Regression: the entry was built through $(printf ...), which strips
    # trailing newlines, so the trailer was welded onto the previous entry's
    # first line and the changelog no longer parsed past entry one.
    eq "the trailer is followed by a blank line, then the previous entry" \
       "" "$(sed -n '6p' "$work/a/debian/changelog")"
    eq "the previous entry survives intact" \
       "demo (1.0.0-1) unstable; urgency=medium" "$(sed -n '7p' "$work/a/debian/changelog")"

    # bump.yml parses this line to fill the PR title and the tag command in
    # its body. The shape is a contract, not just a log message.
    make_pkg "$work/e" fmt 1.0.0 "3.0 (quilt)"
    eq "the result line is '<source> <old> -> <new>'" \
       "fmt 1.0.0-1 -> 1.2.3-1" "$( ( bump "$work/e" v1.2.3 ) 2>/dev/null )"

    # The tag comes from upstream's API, and reaches sed's replacement, where
    # '&' means the whole match. Left unguarded this rewrote package.conf to
    # VERSION=v1VERSION=v1.02.
    # The & must sit in the part upstream_version strips, or dpkg rejects the
    # derived version first and the charset guard is never what refused it.
    # v&2.0.0 derives a valid 2.0.0, passes the comparison, and reaches sed.
    make_pkg "$work/amp" amp 1.0.0 "3.0 (quilt)"
    ( bump "$work/amp" 'v&2.0.0' >/dev/null 2>&1 )
    eq "a tag containing & is refused" "4" "$?"
    eq "the refused & tag left package.conf intact" \
       "VERSION=v1.0.0" "$(grep '^VERSION=' "$work/amp/package.conf")"

    make_pkg "$work/sp" sp 1.0.0 "3.0 (quilt)"
    ( bump "$work/sp" 'v1.0 rm -rf' >/dev/null 2>&1 )
    eq "a tag containing whitespace is refused" "4" "$?"

    # An epoch has no counterpart upstream; deriving a version from the tag
    # would drop it and read as a downgrade to apt.
    # Asserted on the message, not just the code: without the guard the version
    # comparison refuses it too, with the same 4 and a misleading reason.
    make_pkg "$work/ep" ep 1.0.0 "3.0 (quilt)"
    sed -i '1s/(1.0.0-1)/(1:1.0.0-1)/' "$work/ep/debian/changelog"
    ep_err="$( ( bump "$work/ep" v2.0.0 ) 2>&1 >/dev/null || true )"
    eq "a package with an epoch is refused, saying so" \
       "bump: ep carries an epoch (1:1.0.0-1); bump it by hand" "$ep_err"

    make_pkg "$work/b" native 2026.08.15 "3.0 (native)"
    ( bump "$work/b" v2026.09.01 >/dev/null 2>&1 )
    eq "a native package is refused" "4" "$?"

    make_pkg "$work/c" same 3.0.0 "3.0 (quilt)"
    ( bump "$work/c" v3.0.0 >/dev/null 2>&1 )
    eq "an unchanged version reports nothing to do" "3" "$?"

    make_pkg "$work/d" back 5.0.0 "3.0 (quilt)"
    ( bump "$work/d" v4.9.0 >/dev/null 2>&1 )
    eq "a downgrade is refused" "4" "$?"
    eq "a refused bump leaves package.conf untouched" \
       "VERSION=v5.0.0" "$(grep '^VERSION=' "$work/d/package.conf")"

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "bump plan"
(
    # shellcheck source=scripts/plan-bumps.sh
    . "$ROOT/scripts/plan-bumps.sh"

    work="$(mktemp -d)"
    mk() { # dir version [format]
        mkdir -p "$work/$1/debian/source"
        printf '%s\n' "${3:-3.0 (quilt)}" > "$work/$1/debian/source/format"
        printf 'UPSTREAM=https://github.com/x/%s.git\nVERSION=%s\n' "$1" "$2" > "$work/$1/package.conf"
    }
    mk behind v1.0.0
    mk current v2.0.0
    mk native 2026.08.15 "3.0 (native)"
    printf 'behind\ncurrent\nnative\n' > "$work/packages.txt"

    # The upstream is stubbed, so this exercises the plan's own decisions and
    # nothing else. Overriding after the source is the point of the guard.
    latest_tag() { case "$1" in x/behind) echo v1.1.0 ;; x/current) echo v2.0.0 ;; *) echo v9 ;; esac; }
    ROOT="$work"; PACKAGES_FILE="$work/packages.txt"; REPO=""

    out="$(plan)"

    # The regression this exists for: the row append was once deleted while the
    # open-pull-request check above it was rewritten, so the plan detected drift
    # and emitted nothing. It ran green for a day because every package happened
    # to be current, and an empty plan is indistinguishable from a correct one
    # until something is actually behind.
    eq "a package behind upstream produces a row" \
       '[{"package":"behind","tag":"v1.1.0"}]' "$out"

    mk behind v1.1.0
    eq "nothing behind produces an empty array" "[]" "$(plan)"

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "drift dashboard"
(
    render() { bash "$ROOT/scripts/drift-report.sh" "$1" "$2" "https://e/r"; }
    one='[{"package":"croc","tag":"v11.3.6"}]'

    eq "a behind package gets a row" "1" \
       "$(render "$one" success | grep -c '| `croc` | `v11.3.6` |')"

    # skipped is the normal state on a merge, where the dashboard re-renders and
    # nothing is meant to be built. Warning there would put "verification did
    # not pass" on the issue after every successful merge.
    eq "a failed verify warns"      "1" "$(render "$one" failure   | grep -c 'did not pass')"
    eq "a cancelled verify warns"   "1" "$(render "$one" cancelled | grep -c 'did not pass')"
    eq "a skipped verify does not"  "0" "$(render "$one" skipped   | grep -c 'did not pass')"
    eq "a successful verify does not" "0" "$(render "$one" success | grep -c 'did not pass')"

    eq "every row is rendered, not just the first" "2" \
       "$(render '[{"package":"a","tag":"v1"},{"package":"b","tag":"v2"}]' success | grep -c '^| `')"

    exit $((fail > 0))
) || fail=$((fail + 1))

echo "release plan"
(
    # shellcheck source=scripts/plan-release.sh
    . "$ROOT/scripts/plan-release.sh"

    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    mk() { # name version
        mkdir -p "$work/$1/debian"
        printf '%s (%s) unstable; urgency=medium\n' "$1" "$2" > "$work/$1/debian/changelog"
        : > "$work/$1/package.conf"
    }
    mk croc 11.3.6-1
    mk vale 3.19.0-2
    mk epoch 1:2.3-1
    # A changelog in a directory that is not a package, and a changelog one
    # level too deep. Both are shaped like the real thing.
    mkdir -p "$work/docs/debian" "$work/vendor/sub/debian"
    printf 'docs (1-1) unstable; urgency=medium\n'   > "$work/docs/debian/changelog"
    printf 'sub (1-1) unstable; urgency=medium\n'    > "$work/vendor/sub/debian/changelog"
    : > "$work/vendor/package.conf"

    ROOT="$work"
    tagged=""
    tag_exists() { case " $tagged " in *" $1 "*) return 0 ;; esac; return 1; }
    for_paths() { printf '%s\n' "$@" | plan 2>/dev/null; }

    eq "a changed changelog releases at its changelog version" \
       '[{"package":"croc","version":"11.3.6-1","tag":"croc/v11.3.6-1"}]' \
       "$(for_paths croc/debian/changelog)"

    # The trigger is the changelog, because the Debian revision exists nowhere
    # else. package.conf moving on its own cannot name a tag.
    eq "package.conf alone releases nothing" "[]" \
       "$(for_paths croc/package.conf)"

    eq "a directory without package.conf is not a package" "[]" \
       "$(for_paths docs/debian/changelog)"

    # '*/debian/changelog' as a glob would accept this and call the package
    # 'vendor', which has a package.conf and would have released.
    eq "a nested changelog does not name a package" "[]" \
       "$(for_paths vendor/sub/debian/changelog)"

    eq "two packages in one merge both release" "2" \
       "$(for_paths croc/debian/changelog vale/debian/changelog | grep -o '"package"' | wc -l)"

    eq "the same path twice releases once" "1" \
       "$(for_paths croc/debian/changelog croc/debian/changelog | grep -o '"package"' | wc -l)"

    # The idempotency key for the whole path: a re-run, a changelog edit that
    # does not bump, and a hand-pushed tag all land here.
    tagged="croc/v11.3.6-1"
    eq "an existing tag drops that package" \
       '[{"package":"vale","version":"3.19.0-2","tag":"vale/v3.19.0-2"}]' \
       "$(for_paths croc/debian/changelog vale/debian/changelog)"
    eq "and releases nothing when it was the only one" "[]" \
       "$(for_paths croc/debian/changelog)"
    tagged=""

    # A colon cannot be in a ref. Skipping quietly would look exactly like a
    # package with nothing to release, for as long as the epoch survives.
    out="$(printf 'epoch/debian/changelog\n' | plan 2>&1)"; rc=$?
    eq "an epoch fails rather than vanishing" "1" "$rc"
    eq "and names the package that cannot be tagged" "1" \
       "$(printf '%s' "$out" | grep -c 'epoch 1:2.3-1 cannot be a tag name')"

    exit $((fail > 0))
) || fail=$((fail + 1))

echo
if [ "$fail" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$fail failing test group(s)"
fi
exit $((fail > 0))
