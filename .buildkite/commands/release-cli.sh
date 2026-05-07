#!/usr/bin/env bash

set -euo pipefail

# DRAFT-PR PROBE — remove before merging.
# Runs on every BK build (incl. PRs/main, where the publish path is otherwise
# skipped) so we can confirm the agent has `gh` on PATH and authenticated for
# `beeper/platform-imessage` before relying on it for real publishing.
echo "--- :test_tube: probe: gh availability"
command -v gh
gh --version
echo "--- :test_tube: probe: gh auth status"
gh auth status --hostname github.com
echo "--- :test_tube: probe: gh read access on beeper/platform-imessage"
gh release list --repo beeper/platform-imessage --limit 1
gh api /repos/beeper/platform-imessage --jq '.full_name + " (private=" + (.private|tostring) + ")"'
echo "--- :test_tube: probe: bot collaborator permission on beeper/platform-imessage"
# `repo` scope alone isn't enough — the bot account also needs to be a
# collaborator on the repo with at least `write` for `gh release create/upload`
# to succeed. `none`/`read`/`triage` here means real publishing will 403.
bot_login="$(gh api /user --jq .login)"
gh api "/repos/beeper/platform-imessage/collaborators/${bot_login}/permission" \
  --jq '"bot=" + .user.login + " permission=" + .permission'
echo "==> gh probes passed"

# Publish to GitHub Releases only on tag builds. Non-tag builds (PRs,
# main) still produce a signed+notarized tarball — uploaded as a
# Buildkite artifact — for download/testing.
if [ -n "${BUILDKITE_TAG:-}" ]; then
  tag="$BUILDKITE_TAG"
  version="${tag#v}"
  publish=true
else
  base_version="$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')"
  short_sha="${BUILDKITE_COMMIT:0:7}"
  version="${base_version}-${short_sha}"
  publish=false
fi

asset_name="imessage-cli-${version}-macos-universal.tar.gz"

echo "--- :key: install Developer ID cert into the agent keychain"
install_gems
bundle exec fastlane set_up_signing

echo "--- :hammer_and_wrench: build, sign, notarize"
./scripts/sign-and-notarize-cli

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
