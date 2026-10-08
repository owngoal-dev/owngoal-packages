# OwnGoal Packages

Official APT source for OwnGoal Studio.

Add `https://apt.owngoal.dev/` in [Irisin](https://lakr233.github.io/Irisin/) or Sileo.

```text
deb [trusted=yes] https://apt.owngoal.dev/ ./
```

## Packages

Track a GitHub repo in `manifest.json`. The build indexes up to five stable
releases and serves each `.deb` from its GitHub release URL.

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

Or put a `.deb` in `debs/` and push. Control fields are in
[`debs/README.md`](debs/README.md). File names must be unique. Its depiction,
icon, and banner go in `depictions/<package>/`.

`owngoal-essential-apps` (the five OwnGoal apps) and
`owngoal-bootstrap-vphone` (the Procursus base system and command-line tools,
and the essential apps) are metapackages kept in `debs/`. Their sources are the
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
