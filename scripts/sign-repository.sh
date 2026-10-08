#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "Usage: $0 <GPG_KEY_ID> [SITE_DIRECTORY]" >&2
  exit 64
fi

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
site_dir="${2:-$repository_root/_site}"

if [[ "$site_dir" != /* ]]; then
  site_dir="$repository_root/$site_dir"
fi

if [[ ! -f "$site_dir/Release" ]]; then
  echo "Missing $site_dir/Release; build the repository first." >&2
  exit 66
fi

output_dir="$(mktemp -d "$repository_root/.repo-sign.XXXXXX")"
trap 'rm -rf -- "$output_dir"' EXIT

gpg --batch --yes --armor --digest-algo SHA256 \
  --local-user "$1" \
  --detach-sign \
  --output "$output_dir/Release.gpg" \
  "$site_dir/Release"

gpg --batch --yes --armor --digest-algo SHA256 \
  --local-user "$1" \
  --clearsign \
  --output "$output_dir/InRelease" \
  "$site_dir/Release"

mv "$output_dir/Release.gpg" "$site_dir/Release.gpg"
mv "$output_dir/InRelease" "$site_dir/InRelease"
