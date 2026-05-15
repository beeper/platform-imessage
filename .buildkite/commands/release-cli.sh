#!/usr/bin/env bash

set -euo pipefail

# Publish to GitHub Releases only on `v*` tag builds. Non-tag builds (PRs,
# main) and non-`v` tags still produce a signed+notarized tarball — uploaded
# as a Buildkite artifact — for download/testing.
case "${BUILDKITE_TAG:-}" in
  v*)
    tag="$BUILDKITE_TAG"
    version="${tag#v}"
    publish=true
    ;;
  *)
    base_version="$(scripts/print-package-version)"
    short_sha="${BUILDKITE_COMMIT:0:7}"
    version="${base_version}-${short_sha}"
    publish=false
    ;;
esac

asset_name="imessage-cli-${version}-macos-universal.tar.gz"

# Fail fast on a missing GitHub token: `gh release` needs it, but without
# this check the gap only surfaces after the full build + notarization
# round-trip — ~10 min wasted plus a burned notary submission.
if "$publish" && [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  printf >&2 "publish requested but neither GH_TOKEN nor GITHUB_TOKEN is set\n"
  exit 1
fi

echo "--- :key: install Developer ID cert into the agent keychain"
install_gems
bundle exec fastlane set_up_signing

echo "--- :hammer_and_wrench: build, sign, notarize"
# Pass `--arch universal` explicitly: the binary path below assumes a
# universal build, and that's the script's default rather than a contract.
./scripts/sign-and-notarize-cli --arch universal

binary=".build/universal/release/imessage-cli"
if [ ! -f "$binary" ]; then
  printf >&2 "expected signed binary at %s\n" "$binary"
  exit 1
fi

echo "--- :package: tarball + sha256"
# Write to dist/ (gitignored) so the pipeline's `artifact_paths` glob can pick
# the files up even if a later step fails — no need for explicit uploads here.
rm -rf dist
mkdir -p dist
cp "$binary" "dist/imessage-cli"
chmod +x "dist/imessage-cli"
tar -czf "dist/$asset_name" -C dist imessage-cli
( cd dist && shasum -a 256 "$asset_name" > "$asset_name.sha256" )

if ! "$publish"; then
  echo "--- :information_source: skipping GitHub release publish (no tag); tarball stashed as Buildkite artifact"
  exit 0
fi

echo "--- :rocket: publish to GitHub release"
# Idempotent: create the release if missing, then upload with --clobber so re-runs replace
if ! gh release view "$tag" --repo beeper/platform-imessage >/dev/null 2>&1; then
  gh release create "$tag" \
    --repo beeper/platform-imessage \
    --title "iMessage CLI $version" \
    --notes "macOS iMessage CLI release for @beeper/platform-imessage $version."
fi

gh release upload "$tag" "dist/$asset_name" "dist/$asset_name.sha256" \
  --repo beeper/platform-imessage \
  --clobber
