#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

manifest_file="${PACKAGE_MANIFEST:-$repository_root/manifest.json}"
download_dir="${PACKAGE_DOWNLOAD_DIR:-$repository_root/downloads}"
fetch_attempts="${PACKAGE_FETCH_ATTEMPTS:-5}"
fetch_delay="${PACKAGE_FETCH_DELAY:-3}"
# At most this many stable releases per repository. A repo with fewer
# contributes all of them. The files themselves stay on GitHub.
keep_versions="${PACKAGE_KEEP_VERSIONS:-8}"

if [[ ! "$keep_versions" =~ ^[1-9][0-9]*$ ]]; then
  echo "PACKAGE_KEEP_VERSIONS must be a positive integer: $keep_versions" >&2
  exit 64
fi

required_commands=(curl jq)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 69
  fi
done

# Debian and macOS ship different front ends for the same digest.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  echo "Missing required command: sha256sum or shasum" >&2
  exit 69
fi

if [[ ! -f "$manifest_file" ]]; then
  echo "Missing package manifest: $manifest_file" >&2
  exit 66
fi

if ! jq -e '
  (.packages | type == "array")
  and all(
    .packages[];
    ((.repository | type) == "string")
    and ((.repository | length) > 0)
    and ((.architectures | type) == "array")
    and ((.architectures | length) > 0)
    and all(
      .architectures[];
      (type == "string") and test("^[A-Za-z0-9._-]+$")
    )
    and ((.architectures | length) == (.architectures | unique | length))
  )
  and (
    ([.packages[].repository] | length)
    == ([.packages[].repository] | unique | length)
  )
' "$manifest_file" >/dev/null; then
  echo "$manifest_file must define unique repositories with non-empty, unique architectures arrays." >&2
  exit 65
fi

# A token is optional for public repositories and only raises the API rate limit,
# but it is required to reach releases in a private repository.
release_token="${PACKAGE_FETCH_TOKEN:-${GITHUB_TOKEN:-}}"

curl_options=(--fail --silent --show-error --location --connect-timeout 15 --max-time 300)
if [[ -n "$release_token" ]]; then
  # curl drops a manually supplied Authorization header when a redirect crosses
  # origins, so the asset download still succeeds on the unauthenticated CDN hop.
  curl_options+=(--header "Authorization: Bearer $release_token")
fi

work_dir="$(mktemp -d "$repository_root/.repo-fetch.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

# Every attempt is retried with exponential backoff because release downloads
# routinely fail on transient API rate limits and CDN hiccups.
retry() {
  local description="$1"
  shift

  local attempt=1
  local delay="$fetch_delay"

  while true; do
    if "$@"; then
      return 0
    fi

    if ((attempt >= fetch_attempts)); then
      echo "$description failed after $fetch_attempts attempts." >&2
      return 1
    fi

    echo "$description failed (attempt $attempt/$fetch_attempts); retrying in ${delay}s." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

list_releases() {
  curl "${curl_options[@]}" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$1/releases?per_page=100" \
    --output "$2"
}

download_file() {
  curl "${curl_options[@]}" \
    --header "Accept: application/octet-stream" \
    "$1" \
    --output "$2"
}

download_asset() {
  local asset_url="$1"
  local output_file="$2"
  local expected_sha="$3"

  if ! download_file "$asset_url" "$output_file"; then
    return 1
  fi

  # A truncated download still exits zero often enough that the archive magic is
  # the only reliable way to reject a partial file before it reaches the index.
  local magic
  magic="$(head -c 7 "$output_file" 2>/dev/null || true)"
  if [[ "$magic" != '!<arch>' ]]; then
    echo "Downloaded file is not a Debian archive: $output_file" >&2
    rm -f -- "$output_file"
    return 1
  fi

  if [[ -n "$expected_sha" ]]; then
    local actual_sha
    actual_sha="$(sha256_of "$output_file")"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      echo "Checksum mismatch: expected $expected_sha, got $actual_sha" >&2
      rm -f -- "$output_file"
      return 1
    fi
  fi
}

rm -rf -- "$download_dir"
mkdir -p "$download_dir"

# Clients download each package straight from its GitHub release, so the build
# records where every fetched file came from: name, download URL, repository.
release_urls_file="$download_dir/release-urls.tsv"
: > "$release_urls_file"

package_count="$(jq '.packages | length' "$manifest_file")"
if ((package_count == 0)); then
  echo "No packages declared in $manifest_file"
  exit 0
fi

for ((package_index = 0; package_index < package_count; package_index++)); do
  repository="$(jq -r --argjson index "$package_index" '.packages[$index].repository // ""' "$manifest_file")"
  architecture_count="$(jq --argjson index "$package_index" '.packages[$index].architectures | length' "$manifest_file")"

  # Accept the browser URL, the clone URL, or a bare owner/name slug.
  slug="$repository"
  slug="${slug#https://github.com/}"
  slug="${slug#http://github.com/}"
  slug="${slug#git@github.com:}"
  slug="${slug%/}"
  slug="${slug%.git}"

  if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Cannot derive an owner/name slug from repository: $repository" >&2
    exit 65
  fi

  releases_file="$work_dir/releases-$package_index.json"
  if ! retry "Listing releases for $slug" list_releases "$slug" "$releases_file"; then
    exit 75
  fi

  # GitHub returns releases newest first. Take at most keep_versions entries
  # that are neither a draft, a prerelease, nor tagged as a preview build.
  selection_file="$work_dir/selection-$package_index.json"
  jq --argjson keep "$keep_versions" '
    [
      .[]
      | select((.draft | not) and (.prerelease | not))
      | select(
          (.tag_name // "")
          | test("(^|[^A-Za-z0-9])(alpha|beta|rc|pre|preview|dev|nightly|snapshot)([^A-Za-z0-9]|$)"; "i")
          | not
        )
    ][:$keep]
    | map({
        tag: .tag_name,
        assets: (.assets // [])
      })
  ' "$releases_file" > "$selection_file"

  release_count="$(jq 'length' "$selection_file")"
  if ((release_count == 0)); then
    echo "$slug has no stable release." >&2
    exit 65
  fi

  for ((release_index = 0; release_index < release_count; release_index++)); do
    release_file="$work_dir/release-$package_index-$release_index.json"
    jq --argjson index "$release_index" '.[$index]' "$selection_file" > "$release_file"

    release_tag="$(jq -r '.tag' "$release_file")"
    checksums_url="$(jq -r '
      .assets
      | map(select(.name | test("^SHA256SUMS(\\.txt)?$"; "i")))
      | first
      | .url // ""
    ' "$release_file")"

    # Releases that publish a checksum manifest let the download be verified
    # against the digest the build produced, not just against archive corruption.
    # Download it once per release and reuse it for every architecture.
    checksums_file=""
    if [[ -n "$checksums_url" ]]; then
      checksums_file="$work_dir/checksums-$package_index-$release_index.txt"
      if ! retry "Downloading SHA256SUMS from $slug@$release_tag" \
        download_file "$checksums_url" "$checksums_file"; then
        exit 75
      fi
    fi

    for ((architecture_index = 0; architecture_index < architecture_count; architecture_index++)); do
      architecture="$(jq -r \
        --argjson package_index "$package_index" \
        --argjson architecture_index "$architecture_index" \
        '.packages[$package_index].architectures[$architecture_index]' \
        "$manifest_file")"

      IFS=$'\t' read -r asset_name asset_url download_url < <(
        jq -r --arg architecture "$architecture" '
          [
            .assets[]
            | select(.name | test("\($architecture)\\.deb$"; "i"))
          ]
          | first
          | [(.name // ""), (.url // ""), (.browser_download_url // "")]
          | @tsv
        ' "$release_file"
      )

      if [[ -z "$asset_name" ]]; then
        # Older releases may predate a layout; only the newest must ship them all.
        if ((release_index > 0)); then
          echo "Release $release_tag of $slug has no $architecture .deb asset; skipping." >&2
          continue
        fi
        echo "Release $release_tag of $slug has no $architecture .deb asset." >&2
        exit 65
      fi

      expected_sha=""
      if [[ -n "$checksums_file" ]]; then
        expected_sha="$(awk -v name="$asset_name" '
          {
            sub(/\r$/, "")
            sub(/^\*/, "", $2)
            if ($2 == name) {
              print $1
              exit
            }
          }
        ' "$checksums_file")"

        if [[ -z "$expected_sha" ]]; then
          echo "SHA256SUMS of $slug@$release_tag does not list $asset_name; skipping checksum verification." >&2
        fi
      fi

      if [[ -e "$download_dir/$asset_name" ]]; then
        # A release can carry an older build's asset again; the newer release wins.
        if awk -F '\t' -v name="$asset_name" -v slug="$slug" '
          $1 == name && $3 == slug { found = 1 }
          END { exit !found }
        ' "$release_urls_file"; then
          echo "Skipping $asset_name from $slug@$release_tag; a newer release already provides it."
          continue
        fi
        echo "Duplicate package file name across manifest entries: $asset_name" >&2
        exit 65
      fi

      # Clients fetch this URL from Packages, so it must be a public HTTPS
      # browser download link, not the GitHub API asset endpoint.
      if [[ -z "$download_url" || "$download_url" != https://* ]]; then
        echo "Release $release_tag of $slug has no HTTPS download URL for $asset_name." >&2
        exit 65
      fi

      if ! retry "Downloading $asset_name from $slug@$release_tag" \
        download_asset "$asset_url" "$download_dir/$asset_name" "$expected_sha"; then
        exit 75
      fi

      printf '%s\t%s\t%s\n' "$asset_name" "$download_url" "$slug" >> "$release_urls_file"

      if [[ -n "$expected_sha" ]]; then
        echo "Fetched $asset_name from $slug@$release_tag (SHA-256 verified)"
      else
        echo "Fetched $asset_name from $slug@$release_tag"
      fi
    done
  done
done
