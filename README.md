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

Landing releases. Any commit on `master` that changes a package's
`debian/changelog` builds that package for every suite and architecture, runs
its DEP-8 tests, tags it `<package>/vX.Y.Z-N` at that commit, and tells the
archive to ingest. That is true of a bump the automation lands unattended and of
a change you push yourself.

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

`release.yml` also takes a `workflow_dispatch` naming one package, which
releases it at whatever version `master`'s changelog currently carries. That is
the recovery path when a push event was missed, and the way to release a
changelog that landed before any of this existed.

Removing a package from `packages.txt` stops future builds. It does not remove
the package from the archive, which is a separate deliberate act.

## Upstream drift

A scheduled workflow checks every enrolled package against its upstream every
six hours, and lands a commit on `master` for each one that has fallen behind.
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

### Nothing approves a bump

Each one is built and DEP-8 tested across all three suites **before** it lands,
and a package that fails is not landed. That gate is amd64 only; the full three
suites by two architectures runs on the commit, which is also when anything
reaches the archive, and a third time at ingest.

The land job asks about its own package's legs rather than the run's aggregate.
Gating on the aggregate would let one broken package hold every other package's
bump for as long as it stayed broken.

### The dashboard

One issue, `Upstream release drift`, rewritten each run and closed when there is
nothing to say. With nobody approving anything it is the only place any of this
is visible, so it carries what a person watching merges would have noticed
without being asked:

- **A status per row.** `landed, releasing`, `verification failed`,
  `not verified`. It used to print one line for the whole run, and which package
  it meant could be inferred from an empty pull-request column. There are no
  pull requests now, so nothing is left to infer from.
- **Packages the archive does not serve.** If a release build fails after the
  changelog has landed, `package.conf` still matches upstream, so the drift
  check calls the package current while users get the old version, and nothing
  retries. A second table names those, per architecture. Re-release one with the
  Release workflow.

A package whose verification failed appears with nothing else to show for it:
no commit was made, and a red run in a repository nobody watches notifies no
one.

### Landing is releasing

The changelog entry a bump writes is exactly what the release path keys on, so
the commit publishes it. See [Releasing](#releasing).

### The keyring is human-only

`pkghaus-archive-keyring/` ships the public half of the archive signing key: it
is what apt uses to verify every other package here, so changing it is how a
compromise escalates. Three things keep the automation out of it. Two are
conventions inside the workflow they constrain, and so fail open if that
workflow is wrong: `plan-bumps.sh` skips a native package, and the commit
pathspec names only the bumped package's two files. The third does not.
`check-keyring-author.sh` reads what actually landed and refuses a bot-authored
commit that touches the directory, whatever the workflow believed it was doing.
It runs in CI and again in the release path, before anything is built.

It reads the author's *name*, not the email: a person with email privacy on has
the same `users.noreply.github.com` domain the bot does.

## Adding a package

Candidates are vetted before any packaging starts: absent from Debian trixie
and sid, no usable upstream `.deb`, no established third-party channel. Then a
directory, a `package.conf`, a `debian/` tree including `debian/tests`, and a
line in `packages.txt` once it builds and its tests pass.

## Licensing

The Apache-2.0 licence at the root covers the packaging work in this
repository. Each package's own licensing is upstream's, declared where Debian
looks for it: `<package>/debian/copyright`.
