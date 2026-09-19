# OwnGoal Packages

Flat APT repository for OwnGoal Studio iOS packages.

## Repository URL

Use the GitHub Pages repository URL:

```text
https://apt.owngoal.dev/
```

The equivalent APT source entry for the unsigned repository is:

```text
deb [trusted=yes] https://apt.owngoal.dev/ ./
```

## Package sources

The index merges two sources:

- `manifest.json` declares GitHub repositories. The build downloads at most
  eight stable releases of each (override with `PACKAGE_KEEP_VERSIONS`) into
  the ignored `downloads/` directory, reads their control metadata, then
  writes each package's GitHub release URL into `Filename`. Those `.deb`
  files are not published to Pages. A repository with fewer than eight stable
  releases contributes all of them.
- `debs/` holds `.deb` files that are committed directly and served from
  this repository.

Two packages may not share a file name.

### Track a GitHub release

Add an entry to `manifest.json`:

```json
{
  "packages": [
    {
      "repository": "https://github.com/owngoal-dev/CocoaInspector",
      "architectures": ["iphoneos-arm64e", "iphoneos-arm64"]
    }
  ]
}
```

`repository` accepts a browser URL, a clone URL, or a bare `owner/name` slug.
`architectures` is a required, non-empty array. Each value selects the release
asset whose file name ends in `<architecture>.deb`. A repository is declared
once, and every listed jailbreak layout reaches the pool under its own file
name.

`./scripts/fetch-packages.sh` resolves at most eight releases that are not a
draft, not a prerelease, and not tagged as a preview build (`alpha`, `beta`,
`rc`, `pre`, `preview`, `dev`, `nightly`, `snapshot`). Every API call and
download is retried with exponential backoff. A downloaded file is rejected
unless it carries the Debian archive magic and, when the release also publishes
a `SHA256SUMS` asset that lists it, matches the recorded digest. A rejected
file is discarded and downloaded again. The newest selected release must ship
every listed architecture; older selected releases may omit one and are then
skipped for that layout. The build fails when a declared repository has no
stable release or the newest one has no matching asset, so a package is never
silently dropped from the index.

Set `PACKAGE_FETCH_TOKEN` to reach releases in a private source repository. The
workflow falls back to the default `GITHUB_TOKEN`, which only raises the public
API rate limit.

### Commit a package directly

1. Copy the `.deb` file into `debs/`.
2. Commit and push it to `main`.

### Build

The `Build and Deploy APT Repository` workflow downloads the manifest packages,
scans them to build `Packages` / `Release`, rewrites each manifest package's
`Filename` to its GitHub release URL, and deploys the indexes plus committed
`debs/` to GitHub Pages. Downloaded release assets are not uploaded. It runs
on every push that touches the repository inputs, once a day at 04:00 UTC to
pick up new upstream releases, and on demand.

`Packages`, `Packages.xz`, and `Release` are generated during the build and are
intentionally excluded from Git. The workflow verifies their public SHA-256
hashes after each deployment.

For local generation, install `apt-utils`, `xz-utils`, `curl`, and `jq` on Debian
or Ubuntu, then run `./scripts/update-repository.sh`. The complete site is written
to the ignored `_site/` directory. Set `SKIP_PACKAGE_FETCH=1` to build from the
already downloaded packages without contacting GitHub.

Signed releases can be created with
`./scripts/sign-repository.sh <GPG_KEY_ID>` after a local build.

Rebuilding `_site/` removes existing signatures because every metadata change
requires a fresh signature.

## Sileo metadata

Sileo reads repository information from files at the repository root:

- `CydiaIcon.png` is the repository icon.
- `_site/Release` provides the repository name, description, and supported
  architectures.
- `_site/Packages` provides each package name, category, icon, and depiction.

Every package control file must include `Section`. Sileo uses that value to build
software categories. See [`debs/README.md`](debs/README.md) for the supported
package fields.
