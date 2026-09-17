#!/usr/bin/env bash
#
# Helpers shared by the scripts in this directory. Sourced, never executed, so
# it sets no shell options: those belong to whoever sources it.
#
# is_native is why this file exists rather than three copies left alone.
# bump.yml names "plan-bumps.sh skips a native package" as one of the three
# things keeping the automation out of pkghaus-archive-keyring/, and a guard
# that exists twice can be weakened in one copy without the other noticing.
# The two copies had already drifted on whether the argument was a path or a
# name relative to $ROOT.

# The body of a JSON string. Backslashes first, or the quotes escaped on the
# second pass get their new backslash escaped again.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# The version out of a changelog's first line. The same parse bump-upstream.sh
# writes, narrowed to the version.
changelog_version() { # dir
    sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p' "$1/debian/changelog"
}

# A native package is its own upstream: its version tracks the signing key, not
# a release feed, so a tag lookup says nothing about it.
is_native() { # dir
    case "$(cat "$1/debian/source/format" 2>/dev/null)" in
        *native*) return 0 ;;
        *) return 1 ;;
    esac
}
