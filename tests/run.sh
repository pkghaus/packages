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

echo "release in flight"
(
    inflight="$ROOT/scripts/release-in-flight.sh"

    # The direction that matters. An unreachable API must not read as "nothing
    # is running": that is what turns a network blip into an issue accusing a
    # release of having failed.
    eq "an unreachable packages repo counts as in flight" "yes" \
       "$(PACKAGES_REPO=pkghaus/does-not-exist-xyz "$inflight")"
    eq "an unreachable archive repo counts as in flight" "yes" \
       "$(ARCHIVE_REPO=pkghaus/does-not-exist-xyz "$inflight")"

    exit $((fail > 0))
) || fail=$((fail + 1))

echo "drift dashboard"
(
    report="$ROOT/scripts/drift-report.sh"
    two='[{"package":"a","tag":"v1"},{"package":"b","tag":"v2"}]'
    one='[{"package":"a","tag":"v1"}]'
    render() { "$report" "$1" "$2" "$3" https://run/1; }

    eq "a behind package gets a row" "1" \
       "$(render "$one" "$(printf 'a\tsuccess')" '[]' | grep -c '^| `a`')"

    eq "every row is rendered, not just the first" "2" \
       "$(render "$two" "$(printf 'a\tsuccess\nb\tsuccess')" '[]' | grep -c '^| `')"

    # The status is per row now. It used to be one line for the whole run, and
    # which package it meant was inferred from an empty pull-request column --
    # a column Stage 2 removes.
    eq "a passing package says it landed" "1" \
       "$(render "$one" "$(printf 'a\tsuccess')" '[]' | grep -c 'landed, releasing')"
    eq "a failed package says so, in its own row" "1" \
       "$(render "$two" "$(printf 'a\tsuccess\nb\tfailure')" '[]' \
          | grep -c '^| `b`.*verification failed')"
    eq "and the passing one alongside it still says landed" "1" \
       "$(render "$two" "$(printf 'a\tsuccess\nb\tfailure')" '[]' \
          | grep -c '^| `a`.*landed')"
    eq "a cancelled package says cancelled" "1" \
       "$(render "$one" "$(printf 'a\tcancelled')" '[]' | grep -c 'verification cancelled')"

    # An issue raised only by the stuck check used to open with a bare header
    # and nothing under it, which is the first thing a reader sees and has to
    # decode. The stuck table below already followed this rule; the upstream
    # one did not.
    stuck='[{"package":"k","arch":"amd64","packaged":"2","published":"1"}]'
    eq "nothing behind upstream prints no table header" "0" \
       "$(render '[]' '' "$stuck" | grep -c '^| package | upstream tag')"
    eq "it says so in words instead" "1" \
       "$(render '[]' '' "$stuck" | grep -c 'Every enrolled package matches its newest upstream release')"
    eq "and the stuck table is still rendered beneath it" "1" \
       "$(render '[]' '' "$stuck" | grep -c '^| `k` | amd64')"
    eq "a behind package still gets its header" "1" \
       "$(render "$one" "$(printf 'a\tsuccess')" '[]' | grep -c '^| package | upstream tag')"

    # The load-bearing one. A package the status table never mentioned must not
    # read as fine, or a reporter that silently found nothing looks like a clean
    # run.
    eq "a package with no status reads as not verified" "1" \
       "$(render "$one" "" '[]' | grep -c 'not verified')"
    eq "and never as landed" "0" \
       "$(render "$one" "" '[]' | grep -c 'landed')"

    stuck='[{"package":"ouch","arch":"arm64","packaged":"0.8.3-1","published":"0.8.2-1"}]'
    eq "nothing stuck renders no second table" "0" \
       "$(render "$one" "$(printf 'a\tsuccess')" '[]' | grep -c 'Packaged but not published')"
    eq "a stuck package renders the second table" "1" \
       "$(render "$one" "$(printf 'a\tsuccess')" "$stuck" | grep -c 'Packaged but not published')"
    eq "and names the package, arch and both versions" "1" \
       "$(render "$one" "$(printf 'a\tsuccess')" "$stuck" \
          | grep -c '^| `ouch` | arm64 | `0.8.3-1` | `0.8.2-1` |')"

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

echo "keyring guard"
(
    guard="$ROOT/scripts/check-keyring-author.sh"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    git -C "$work" init -q -b master .
    mk() { # author file
        mkdir -p "$work/$(dirname "$2")"
        echo "$2 $RANDOM" > "$work/$2"
        git -C "$work" add -A
        git -C "$work" -c user.name="$1" -c user.email=x@y.z \
            -c commit.gpgsign=false commit -q -m "touch $2"
    }
    at() { git -C "$work" rev-parse HEAD; }
    run() { ROOT="$work" "$guard" "$1" HEAD >/dev/null 2>&1; echo $?; }

    mk "Martin Simon" README.md
    base="$(at)"

    # A person may change the keyring. That is the whole point: it is the one
    # directory the automation must not reach, not one nobody may touch.
    mk "Martin Simon" pkghaus-archive-keyring/debian/changelog
    eq "a person may touch the keyring"        "0" "$(run "$base")"
    b2="$(at)"

    mk "github-actions[bot]" croc/package.conf
    eq "a bot may touch an ordinary package"   "0" "$(run "$b2")"
    b3="$(at)"

    mk "github-actions[bot]" pkghaus-archive-keyring/debian/changelog
    eq "a bot may not touch the keyring"       "1" "$(run "$b3")"

    # The range, not just the tip. The bad commit has to sit BEHIND the tip for
    # this to test anything -- the first version of this assertion put it AT the
    # tip, so a check that read only the tip still passed it. Caught by mutating
    # rev-list to -1.
    mk "Martin Simon" README.md
    eq "a bad commit behind the tip still fails" "1" "$(run "$b3")"
    eq "and the tip alone is clean"              "0" "$(run "$(git -C "$work" rev-parse HEAD~1)")"

    # Email cannot distinguish them -- a person with email privacy on has the
    # same users.noreply.github.com domain as the bot -- so the check reads the
    # author name. This asserts the domain alone does not trip it.
    mkdir -p "$work/pkghaus-archive-keyring/debian"
    echo x > "$work/pkghaus-archive-keyring/debian/control"
    git -C "$work" add -A
    git -C "$work" -c user.name="Martin Simon" \
        -c user.email="1234+barnumbirr@users.noreply.github.com" \
        -c commit.gpgsign=false commit -q -m "human with a noreply address"
    eq "a noreply address alone is not a bot"  "0" "$(run "$(git -C "$work" rev-parse HEAD~1)")"

    exit $((fail > 0))
) || fail=$((fail + 1))

echo "verify status"
(
    vs="$ROOT/scripts/verify-status.sh"
    jobs='{"jobs":[
      {"name":"Find upstream releases","conclusion":"success"},
      {"name":"a v1 / trixie","conclusion":"success"},
      {"name":"a v1 / testing","conclusion":"success"},
      {"name":"a v1 / unstable","conclusion":"success"},
      {"name":"b v2 / trixie","conclusion":"failure"},
      {"name":"b v2 / testing","conclusion":"success"},
      {"name":"b v2 / unstable","conclusion":"cancelled"},
      {"name":"Drift dashboard","conclusion":"success"}]}'
    m='[{"package":"a","tag":"v1"},{"package":"b","tag":"v2"},{"package":"c","tag":"v3"}]'
    got="$(printf '%s' "$jobs" | "$vs" "$m")"

    eq "all legs green is success"        "a	success"   "$(printf '%s\n' "$got" | grep '^a')"
    # failure outranks cancelled: a cancelled leg alongside a real failure must
    # not soften the verdict.
    eq "any failing leg is failure"       "b	failure"   "$(printf '%s\n' "$got" | grep '^b')"
    eq "a package with no legs is unknown" "c	unknown"  "$(printf '%s\n' "$got" | grep '^c')"
    eq "jobs that are not legs are ignored" "3"          "$(printf '%s\n' "$got" | grep -c .)"

    cx='{"jobs":[{"name":"a v1 / trixie","conclusion":"cancelled"},
                 {"name":"a v1 / testing","conclusion":"success"}]}'
    eq "cancelled without failure is cancelled" "a	cancelled" \
       "$(printf '%s' "$cx" | "$vs" '[{"package":"a","tag":"v1"}]')"

    # gh api --paginate --slurp wraps the pages in a list. A run with more than
    # a page of jobs must not lose the ones on page two.
    pg='[{"jobs":[{"name":"a v1 / trixie","conclusion":"success"}]},
         {"jobs":[{"name":"a v1 / testing","conclusion":"failure"}]}]'
    eq "a paginated payload is read across pages" "a	failure" \
       "$(printf '%s' "$pg" | "$vs" '[{"package":"a","tag":"v1"}]')"

    ip='{"jobs":[{"name":"a v1 / trixie","status":"in_progress","conclusion":null}]}'
    eq "an unfinished leg is named, not rounded to success" "a	in_progress" \
       "$(printf '%s' "$ip" | "$vs" '[{"package":"a","tag":"v1"}]')"

    exit $((fail > 0))
) || fail=$((fail + 1))

echo "published check"
(
    . "$ROOT/scripts/check-published.sh"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    mk() { mkdir -p "$work/$1/debian"
           printf '%s (%s) unstable; urgency=medium\n' "$1" "$2" > "$work/$1/debian/changelog"; }
    mk ouch 0.8.3-1
    mk croc 11.3.6-1
    printf 'ouch\ncroc\n' > "$work/packages.txt"
    printf 'Package: ouch\nVersion: 0.8.2-1\n\nPackage: croc\nVersion: 11.3.6-1\n' > "$work/amd64"
    cp "$work/amd64" "$work/arm64"

    ROOT="$work"; PACKAGES_FILE="$work/packages.txt"; ARCHES="amd64 arm64"
    fetch_index() { cat "$work/$1"; }

    out="$(published)"
    eq "a package the archive serves at an older version is reported" "2" \
       "$(printf '%s' "$out" | grep -o '"package":"ouch"' | wc -l)"
    eq "a current package is not"                                     "0" \
       "$(printf '%s' "$out" | grep -o '"package":"croc"' | wc -l)"

    printf 'Package: croc\nVersion: 11.3.6-1\n' > "$work/arm64"
    eq "a package absent from one arch is reported for that arch" "1" \
       "$(published | grep -o '"published":"<absent>"' | wc -l)"

    cp "$work/amd64" "$work/arm64"
    sed -i 's/0.8.2-1/0.8.3-1/' "$work/amd64" "$work/arm64"
    eq "everything published is an empty array" "[]" "$(published)"

    # A network failure must not read as "every package is stuck". It reports
    # nothing and fails, so the caller can tell the difference.
    fetch_index() { return 1; }
    published >/dev/null 2>&1
    eq "an unreadable index fails rather than reporting" "1" "$?"

    exit $((fail > 0))
) || fail=$((fail + 1))

echo
if [ "$fail" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$fail failing test group(s)"
fi
exit $((fail > 0))
