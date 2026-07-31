# OwnGoal Packages

Official APT source for OwnGoal Studio.

Add `https://apt.owngoal.dev/` in Irisin, Sileo, or Zebra.

```text
deb [trusted=yes] https://apt.owngoal.dev/ ./
```

## Packages

Track a GitHub repo in `manifest.json`. The build indexes up to eight stable
releases and serves each `.deb` from its GitHub release URL.

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

Or put a `.deb` in `debs/` and push. Control fields are in
[`debs/README.md`](debs/README.md). File names must be unique.

## Featured

`sileo-featured.json` is the banner list at the top of this source. Fila,
iGhostVT, Inspector, and Irisin are featured, using each package's depiction
image.

## Publish

Push to `main` or run **Build and Deploy APT Repository**. Pages gets the
indexes and committed `debs/`. A daily run at 04:00 UTC picks up new releases.

On Debian or Ubuntu, `./scripts/update-repository.sh` writes the same site to
`_site/`.
