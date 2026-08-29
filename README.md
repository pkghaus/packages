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
├── package.conf        UPSTREAM and VERSION: the upstream repo and the tag to build
└── debian/             the packaging: control, rules, changelog, copyright, tests
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

Tags are namespaced by package, and the version matches `debian/changelog`:

```sh
git tag -s <package>/vX.Y.Z-N -m "<package> X.Y.Z-N"
git push origin <package>/vX.Y.Z-N
```

That builds the package for every suite and architecture, runs its DEP-8 tests,
and tells the archive to ingest it. Tags are always signed.

Removing a package from `packages.txt` stops future builds. It does not remove
the package from the archive, which is a separate deliberate act.

## Adding a package

Candidates are vetted before any packaging starts: absent from Debian trixie
and sid, no usable upstream `.deb`, no established third-party channel. Then a
directory, a `package.conf`, a `debian/` tree including `debian/tests`, and a
line in `packages.txt` once it builds and its tests pass.

## Licensing

The Apache-2.0 licence at the root covers the packaging work in this
repository. Each package's own licensing is upstream's, declared where Debian
looks for it: `<package>/debian/copyright`.
