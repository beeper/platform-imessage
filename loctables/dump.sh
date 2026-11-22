#!/usr/bin/env bash
set -eu -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

usage() {
  echo "usage: $0 [dump|format] [--ipsw <https-url|latest>] [--output <directory>]" >&2
}

command="dump"
if [[ $# -gt 0 && "$1" != -* ]]; then
  command="$1"
  shift
fi
ipsw_url=""
output_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipsw|--output)
      if [[ $# -lt 2 || -z "$2" ]]; then usage; exit 1; fi
      if [[ "$1" == "--ipsw" ]]; then ipsw_url="$2"; else output_dir="$2"; fi
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
if [[ "$command" != "dump" && "$command" != "format" ]]; then usage; exit 1; fi
if [[ "$command" == "format" && -n "$ipsw_url" ]]; then
  echo "--ipsw is only supported by dump" >&2
  exit 1
fi
if [[ -n "$ipsw_url" && "$ipsw_url" != "latest" && "$ipsw_url" != https://* ]]; then
  echo "--ipsw requires an HTTPS URL or latest" >&2
  exit 1
fi

tmp_dir=""
cleanup() {
  if [[ -n "$tmp_dir" ]]; then rm -rf "$tmp_dir"; fi
}
trap cleanup EXIT

root=""
if [[ -n "$ipsw_url" ]]; then
  ipsw_bin="${IPSW_BIN:-ipsw}"
  if ! command -v "$ipsw_bin" >/dev/null 2>&1; then
    echo "Remote mode requires KishanBagaria/ipsw; see loctables/readme.md (or set IPSW_BIN)." >&2
    exit 1
  fi
  extract_help="$("$ipsw_bin" extract --help)"
  if [[ "$extract_help" != *"--ranged-dmg"* ]]; then
    echo "This ipsw lacks ranged extraction. Build KishanBagaria/ipsw branch codex/remote-filesystem-ranges and set IPSW_BIN." >&2
    exit 1
  fi
  if [[ "$ipsw_url" == "latest" ]]; then
    ipsw_url="$("$ipsw_bin" download ipsw --macos --latest --device VirtualMac2,1 --urls)"
  fi
  if [[ "$ipsw_url" != https://* || "$ipsw_url" == *$'\n'* ]]; then
    echo "Expected one HTTPS UniversalMac IPSW URL; pass an explicit --ipsw URL." >&2
    exit 1
  fi
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/loctables.XXXXXX")"
  "$ipsw_bin" info --remote --json "$ipsw_url" > "$tmp_dir/info.json"
  product_version="$(plutil -extract version raw "$tmp_dir/info.json")"
  build_version="$(plutil -extract build raw "$tmp_dir/info.json")"
  "$ipsw_bin" extract --remote --files --ranged --ranged-dmg fs \
    --device "${IPSW_DEVICE:-Macmini9,1}" \
    --pattern '^/System/((Library|iOSSupport/System/Library)/(PrivateFrameworks|AccessibilityBundles)/(Chat|IM).*\.loctable|Library/ExtensionKit/Extensions/SecurityPrivacyExtension\.appex/Contents/Resources/Localizable\.loctable)$' \
    --output "$tmp_dir/extracted" "$ipsw_url"
  # ipsw preserves System/... beneath its build/device output directory.
  shopt -s nullglob
  system_dirs=("$tmp_dir"/extracted/*/System)
  if [[ ${#system_dirs[@]} -eq 0 ]]; then
    echo "No matching loctables found in macOS $product_version ($build_version)" >&2
    exit 1
  elif [[ ${#system_dirs[@]} -ne 1 ]]; then
    echo "Expected one extracted System directory from ipsw" >&2
    exit 1
  fi
  root="${system_dirs[0]%/System}"
else
  product_version="$(sw_vers --productVersion)"
  build_version="$(sw_vers --buildVersion)"
fi
# These values become output paths; reject unexpected manifest metadata.
if [[ ! "$product_version" =~ ^[0-9]+(\.[0-9]+)*$ || ! "$build_version" =~ ^[a-zA-Z0-9]+$ ]]; then
  echo "Invalid macOS product/build version" >&2
  exit 1
fi
safe_product_version="${product_version//\./_}"
ver="$product_version-$build_version"
safe_ver="$safe_product_version-$build_version"
output_dir="${output_dir:-$ver}"

format() {
  yarn prettier -w "$@"
}

if [[ "$command" == "format" ]]; then
  format "$output_dir"/*.json
  exit 0
fi

mkdir -p "$output_dir"
# nullglob avoids passing missing framework globs to find. NUL-delimited paths
# also handle spaces in bundle/resource names.
shopt -s nullglob
search_roots=(
  "$root"/System/iOSSupport/System/Library/PrivateFrameworks/Chat*
  "$root"/System/iOSSupport/System/Library/PrivateFrameworks/IM*
  "$root"/System/iOSSupport/System/Library/AccessibilityBundles/Chat*
  "$root"/System/iOSSupport/System/Library/AccessibilityBundles/IM*
  "$root"/System/Library/PrivateFrameworks/Chat*
  "$root"/System/Library/PrivateFrameworks/IM*
  "$root"/System/Library/AccessibilityBundles/Chat*
  "$root"/System/Library/AccessibilityBundles/IM*
)
privacy_table="$root/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable"
if [[ -f "$privacy_table" ]]; then search_roots+=("$privacy_table"); fi
if [[ ${#search_roots[@]} -eq 0 ]]; then
  echo "No matching localization resources" >&2
  exit 1
fi
# Materialize find's result so failures propagate outside process substitution.
if [[ -z "$tmp_dir" ]]; then tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/loctables.XXXXXX")"; fi
find "${search_roots[@]}" -type f -name '*.loctable' -print0 | sort -z > "$tmp_dir/paths"
count=0
while IFS= read -r -d '' loctable_path; do
  if [[ "$loctable_path" =~ IMAP\. ]]; then continue; fi
  bundle_re="([a-zA-Z0-9_-]+)\.(framework|axbundle|appex)"
  if ! [[ "${loctable_path#"$root"}" =~ $bundle_re ]]; then continue; fi
  bundle_name="${BASH_REMATCH[1]}"
  loctable_filename="$(basename "$loctable_path")"
  dest_basename="${bundle_name}-${loctable_filename%.loctable}"
  dest_path="${output_dir}/${dest_basename}-${safe_ver}.json"
  printf '\x1b[1mDUMP\x1b[0m %s\n' "${loctable_path#"$root"}"
  plutil -convert json -o "$dest_path" -- "$loctable_path"
  count=$((count + 1))
done < "$tmp_dir/paths"
if [[ "$count" -eq 0 ]]; then echo "No matching loctables found" >&2; exit 1; fi
# One foreground invocation reports formatter failures and avoids one process per file.
format "$output_dir"/*.json
printf 'Dumped %s loctables to %s\n' "$count" "$output_dir"
