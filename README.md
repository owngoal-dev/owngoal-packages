# OwnGoal Packages

Official APT source for OwnGoal Studio.

Add `https://apt.owngoal.dev/` in [Irisin](https://lakr233.github.io/Irisin/).

```text
deb [trusted=yes] https://apt.owngoal.dev/ ./
```

## Packages

Track a GitHub repo in `manifest.json`. The build indexes its three newest
stable releases and the newest release of the minor version before them, at
most four, and serves each `.deb` from its GitHub release URL. Depiction
changelogs show the five newest releases.

```json
{
  "packages": [
    {
      "repository": "https://github.com/owngoal-dev/Inspector",
      "architectures": ["iphoneos-arm64e", "iphoneos-arm64"]
    }
  ]
}
```

Each release contributes its first `.deb` for each architecture. Add
`"allPackages": true` when a release ships several packages, such as an app
and its extensions, to index every one of them.

Or put a `.deb` in `debs/` and push. Control fields are in
[`debs/README.md`](debs/README.md). File names must be unique. Its depiction,
icon, and banner go in `depictions/<package>/`.

`owngoal-essential-apps` (the five OwnGoal apps) and
`owngoal-bootstrap-vphone` (the Procursus base system and command-line tools,
and the essential apps; on Apple TV, OwnGoal Stripe's builds of those tools and
Irisin) are metapackages kept in `debs/`. Their sources are the
`owngoal-essential-apps` and `owngoal-bootstrap-vphone` projects; `make publish`
there updates `debs/` and `depictions/`.

## Featured

`sileo-featured.json` is the banner list at the top of this source. Fila,
iGhostVT, Inspector, and Irisin are featured, using each package's depiction
image.

## Publish

Push to `main` or run **Build and Deploy APT Repository**. Pages gets the
indexes and committed `debs/`. A daily run at 04:00 UTC picks up new releases.

On Debian or Ubuntu, `./scripts/update-repository.sh` writes the same site to
`_site/`.
