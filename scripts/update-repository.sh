#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

required_commands=(apt-ftparchive xz)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 69
  fi
done

download_dir="${PACKAGE_DOWNLOAD_DIR:-$repository_root/downloads}"

# Release assets must land on disk before the pool is scanned, otherwise the
# generated indexes would omit every manifest package.
if [[ "${SKIP_PACKAGE_FETCH:-0}" != "1" ]]; then
  PACKAGE_DOWNLOAD_DIR="$download_dir" "$repository_root/scripts/fetch-packages.sh"
fi

work_dir="$(mktemp -d "$repository_root/.repo-build.XXXXXX")"
site_dir="$work_dir/site"
index_dir="$work_dir/indexes"
pool_dir="$work_dir/pool"
output_dir="$repository_root/_site"
mkdir -p "$site_dir" "$index_dir" "$pool_dir/debs"
trap 'rm -rf -- "$work_dir"' EXIT

# Scan a local pool so apt-ftparchive can read control data and hashes.
# Manifest packages are then published with their GitHub release URLs, and
# only committed debs stay in the Pages artifact.
shopt -s nullglob
committed_packages=("$repository_root/debs"/*.deb)
pool_sources=("$repository_root/debs"/*.deb "$download_dir"/*.deb)
shopt -u nullglob

if ((${#pool_sources[@]} == 0)); then
  echo "No packages available to index." >&2
  exit 65
fi

release_urls_file="$download_dir/release-urls.tsv"

for package_file in "${pool_sources[@]}"; do
  package_name="$(basename -- "$package_file")"

  if [[ -e "$pool_dir/debs/$package_name" ]]; then
    echo "Duplicate package file name in the pool: $package_name" >&2
    exit 65
  fi

  case "$package_file" in
    "$download_dir"/*)
      if [[ ! -f "$release_urls_file" ]] || ! awk -F '\t' -v name="$package_name" '
        $1 == name && $2 ~ /^https:\/\// { found = 1 }
        END { exit !found }
      ' "$release_urls_file"; then
        echo "Downloaded package has no GitHub release URL: $package_name" >&2
        exit 65
      fi
      ;;
  esac

  # The scanned pool can be several gigabytes; hardlink instead of copying.
  if ! ln "$package_file" "$pool_dir/debs/$package_name" 2>/dev/null; then
    cp "$package_file" "$pool_dir/debs/$package_name"
  fi
done

# Scan the assembled pool and generate every repository index. Running from the
# pool root keeps each package Filename relative (debs/<package>.deb).
(cd "$pool_dir" && apt-ftparchive packages debs) > "$index_dir/Packages"

awk '
  BEGIN {
    RS = ""
    FS = "\n"
  }

  {
    package = ""
    section = ""

    for (field = 1; field <= NF; field++) {
      if ($field ~ /^Package: /) {
        package = substr($field, 10)
      }

      if ($field ~ /^Section: /) {
        section = substr($field, 10)
      }
    }

    if (package != "" && section == "") {
      printf "Package %s is missing the Section field required by Sileo.\n", package > "/dev/stderr"
      exit 1
    }
  }
' "$index_dir/Packages"

# apt-ftparchive only emits relative paths. Sileo, Zebra, and apt all fetch an
# absolute Filename as-is, so rewrite after the scan; Size and SHA-256 still
# describe the file we hashed.
if [[ -s "$release_urls_file" ]]; then
  rewritten_file="$index_dir/Packages.rewritten"
  awk -v urls_file="$release_urls_file" '
    BEGIN {
      while ((getline line < urls_file) > 0) {
        split(line, fields, "\t")
        name = fields[1]
        url = fields[2]
        if (name != "" && url ~ /^https:\/\//) {
          urls[name] = url
        }
      }
      close(urls_file)
    }

    /^Filename: / {
      path = $0
      sub(/^Filename: /, "", path)
      file = path
      sub(/^.*\//, "", file)
      if (file in urls) {
        print "Filename: " urls[file]
        seen[file] = 1
        next
      }
    }

    { print }

    END {
      missing = 0
      for (name in urls) {
        if (!(name in seen)) {
          printf "Packages is missing rewritten Filename for %s\n", name > "/dev/stderr"
          missing = 1
        }
      }
      if (missing) {
        exit 1
      }
    }
  ' "$index_dir/Packages" > "$rewritten_file"
  mv "$rewritten_file" "$index_dir/Packages"
fi

xz -9e -c "$index_dir/Packages" > "$index_dir/Packages.xz"

# Keeping Release outside the scanned directory prevents a self-referential hash.
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="OwnGoal Studio" \
  -o APT::FTPArchive::Release::Label="OwnGoal Packages" \
  -o APT::FTPArchive::Release::Suite="stable" \
  -o APT::FTPArchive::Release::Version="1.0" \
  -o APT::FTPArchive::Release::Codename="owngoal" \
  -o APT::FTPArchive::Release::Architectures="iphoneos-arm iphoneos-arm64 iphoneos-arm64e xros-arm64e" \
  -o APT::FTPArchive::Release::Components="main" \
  -o APT::FTPArchive::Release::Description="Official iOS packages from OwnGoal Studio" \
  release "$index_dir" > "$work_dir/Release"

# Assemble the Pages artifact only after all metadata has been generated.
# Downloaded release assets are not copied; clients fetch them from GitHub.
cp -R assets "$site_dir/assets"
if ((${#committed_packages[@]} > 0)); then
  mkdir -p "$site_dir/debs"
  for package_file in "${committed_packages[@]}"; do
    cp "$package_file" "$site_dir/debs/$(basename -- "$package_file")"
  done
fi
cp CNAME CydiaIcon.png index.html manifest.json "$site_dir/"
cp "$index_dir/Packages" "$index_dir/Packages.xz" "$site_dir/"
cp "$work_dir/Release" "$site_dir/Release"

rm -rf -- "$output_dir"
mv "$site_dir" "$output_dir"

echo "Built APT repository at $output_dir"
