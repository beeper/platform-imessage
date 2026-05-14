#!/usr/bin/env bash
set -eu -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

product_version="$(sw_vers --productVersion)"   # e.g. 26.0
safe_product_version="${product_version//\./_}" # e.g. 26_0 (s/./_)
build_version="$(sw_vers --buildVersion)"       # e.g. 25A5346a

ver="$product_version-$build_version"
safe_ver="$safe_product_version-$build_version"
mkdir -p "$ver"

command="${1:-dump}"

dump() {
  plutil -convert json -o "$2" -- "$1"
}

format() {
  yarn prettier -w "$@"
}

if [[ "$command" == "format" ]]; then
  format "$ver"/*.json
  exit 0
elif [[ "$command" != "dump" ]]; then
  echo "usage: $0 [dump|format]" >&2
  exit 1
fi

for loctable_path in $(find \
  /System/iOSSupport/System/Library/PrivateFrameworks/Chat* \
  /System/iOSSupport/System/Library/PrivateFrameworks/IM* \
  /System/iOSSupport/System/Library/AccessibilityBundles/Chat* \
  /System/iOSSupport/System/Library/AccessibilityBundles/IM* \
  /System/Library/PrivateFrameworks/Chat* \
  /System/Library/PrivateFrameworks/IM* \
  /System/Library/AccessibilityBundles/Chat* \
  /System/Library/AccessibilityBundles/IM* \
  -type f \
  -name "*.loctable" \
  2>/dev/null | sort); do
  # likely for mail, we can ignore this
  if [[ "$loctable_path" =~ IMAP\. ]]; then
    continue
  fi

  # extract the encompassing framework or accessibility bundle name
  bundle_re="([a-zA-Z0-9_-]+)\.(framework|axbundle)"
  printf "\x1b[1mDUMP\x1b[0m %s\n" "$loctable_path"
  if ! [[ "$loctable_path" =~ $bundle_re ]]; then
    continue
  fi

  framework_name="${BASH_REMATCH[1]}"
  loctable_filename="$(basename "$loctable_path")"
  dest_basename="${framework_name}-${loctable_filename//\.loctable/}"
  dest_path="${ver}/${dest_basename}-${safe_ver}.json"
  dump "$loctable_path" "$dest_path"
  format "$dest_path" >/dev/null 2>&1 &
done

wait
