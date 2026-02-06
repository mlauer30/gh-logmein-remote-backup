#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_root="${script_dir}/../PropertyDetailJsons"
root_dir="${1:-$default_root}"
force_write="false"

if [[ "${2:-}" == "--force" || "${1:-}" == "--force" ]]; then
  force_write="true"
  if [[ "${1:-}" == "--force" ]]; then
    root_dir="${2:-$default_root}"
  fi
fi

if [[ ! -d "$root_dir" ]]; then
  echo "Root directory not found: $root_dir" >&2
  exit 1
fi

created_count=0
skipped_count=0

while IFS= read -r -d '' dir; do
  if find "$dir" -mindepth 1 -type d -print -quit | grep -q .; then
    continue
  fi

  rel_path="${dir#"$root_dir"/}"
  property_folder="${rel_path%%/*}"
  target_folder="$(basename "$dir")"
  output_path="$dir/PcDetails.json"

  if [[ -e "$output_path" && "$force_write" != "true" ]]; then
    skipped_count=$((skipped_count + 1))
    continue
  fi

  cat >"$output_path" <<EOF
{
  "PropertyFolder": "$property_folder",
  "TargetFolder": "$target_folder"
}
EOF
  created_count=$((created_count + 1))
done < <(find "$root_dir" -mindepth 2 -type d -print0)

echo "PcDetails.json created/updated: $created_count"
echo "Skipped existing: $skipped_count"
