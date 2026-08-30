# packages

Debian packaging for every package in the [pkg.haus](https://pkg.haus) archive.
One directory per package, holding a `package.conf` and a `debian/` tree.

Packages are built from source at upstream's own release tags by
[action-debian-build](https://github.com/pkghaus/action-debian-build), for
Debian stable, testing and unstable on amd64 and arm64, and published to
<https://apt.pkg.haus>.

## Layout

```
<package>/
├── package.conf   UPSTREAM and VERSION: the upstream repo and tag to build
└── debian/        the packaging: control, rules, changelog, copyright, tests
```

`packages.txt` lists the packages the archive publishes. A directory that is
not listed is still built on pull requests but never published, which is how a
package is staged while its packaging is reviewed. CI enforces the other
direction: every line in `packages.txt` must have a matching directory.

## Building one locally

```sh
cd <package>
docker run --rm --volume "$PWD:/target" --workdir /target \
    ghcr.io/pkghaus/deb-builder:trixie
```

The `.deb`, its `.buildinfo` and a `.source` sidecar naming the upstream commit
land in `debs/`. Swap `trixie` for `testing` or `unstable` to build the other
suites. Pull the image first: a stale one can predate the pipeline's contract.

## Releasing

Merging releases. A merge to `master` that changes a package's
`debian/changelog` builds that package for every suite and architecture, runs
its DEP-8 tests, tags it `<package>/vX.Y.Z-N` at the merge commit, and tells the
archive to ingest. Approving a bump pull request is the whole release.

The changelog and not `package.conf`, because the tag carries the Debian
revision and that is the only file it exists in. A packaging-only revision
releases on the same path.

That tag is a lightweight ref, deliberately. No GitHub API signs a tag:
`createCommitOnBranch` is the only signing mutation GraphQL exposes and it signs
commits, so the question was which object carries the attestation, not whether
one does. The merge commit carries it. GitHub signs it server-side and records
who pressed the button, and the archive verifies nothing about the tag object
anyway, since it clones `--branch` and rebuilds from source.

Pushing a signed tag by hand still works and still releases:

```sh
git tag -s <package>/vX.Y.Z-N -m "<package> X.Y.Z-N"
git push origin <package>/vX.Y.Z-N
```

Both paths cannot fire for one version. The release plan drops any package whose
tag already exists, which is also what makes a re-run and a changelog edit that
does not bump into no-ops.

Removing a package from `packages.txt` stops future builds. It does not remove
the package from the archive, which is a separate deliberate act.

## Upstream drift

A scheduled workflow checks every enrolled package against its upstream every
six hours and opens a pull request for each one that has fallen behind. It
rewrites
`package.conf`'s `VERSION` and adds a `debian/changelog` entry, and nothing
else.

**Every upstream tag is tracked.** There is no staleness threshold and no
filtering: a different tag string from the one in `package.conf` is the whole
rule. Some upstreams release often, croc cut six in five days in August, and
the cost of following all of them is accepted deliberately.

Upstream's newest release comes from GitHub's `releases/latest`, which is
upstream's own declaration of what counts as released, with a sorted-tag
fallback for projects that publish no releases. Deliberately not `debian/watch`
and uscan: a tag carries no prerelease flag, so a watch file reports whichever
string sorts highest, which on one fleet upstream is a release candidate.
Watch files are still owed for Debian policy; they are not this.

Three kinds of package are left alone: one that is not in `packages.txt`, one
whose `debian/source/format` is native (`pkghaus-archive-keyring` is its own
upstream, so a tag lookup says nothing about it), and one whose upstream lookup
fails, which is reported rather than treated as up to date.

The bump also refuses, rather than guesses, three things: a tag that is not a
plain version tag, a package carrying an epoch, and any move that is not
strictly forward. A downgrade is the one mistake here a reviewer skimming a
two-line diff would not catch.

### Checks on those pull requests

They are gated, not absent. This section claimed otherwise for a day and a half.
Both runs on the first bump pull request were created three seconds after it
opened and sat at `action_required`: GitHub holds workflows on a first-time
contributor's pull request until somebody approves them, and
`github-actions[bot]` was one. It has a merged pull request here now, so the
gate may be gone. No bump has opened since to show it.

Either way the bump is verified **before** the pull request exists: the workflow
applies it and builds and DEP-8 tests the result across all three suites, and a
package that fails never gets a pull request. The run is linked from the body.

That gate is amd64 only. The full three suites by two architectures runs on the
merge, which is also when anything reaches the archive.

### The dashboard

One issue, `Upstream release drift`, is rewritten each run: what is behind, and
where its pull request is. It closes itself when everything is current.

It is also re-rendered whenever a `package.conf` lands on master, so merging a
bump updates or closes it within seconds rather than leaving it wrong until the
next scheduled run. A merge only re-renders: it never builds, and never opens a
pull request for some unrelated package that happens to be behind at the time.

It exists for the case a pull request cannot cover. A package whose build or
DEP-8 tests fail never gets one, so without the issue that package would be
invisible: no pull request, and a red run in a repository nobody watches
notifies nobody.

### Merging is releasing

The changelog entry a bump adds is exactly what the release path keys on, so
approving one publishes it. See [Releasing](#releasing).

## Adding a package

Candidates are vetted before any packaging starts: absent from Debian trixie
and sid, no usable upstream `.deb`, no established third-party channel. Then a
directory, a `package.conf`, a `debian/` tree including `debian/tests`, and a
line in `packages.txt` once it builds and its tests pass.

## Licensing

The Apache-2.0 licence at the root covers the packaging work in this
repository. Each package's own licensing is upstream's, declared where Debian
looks for it: `<package>/debian/copyright`.
