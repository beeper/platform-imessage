#!/usr/bin/env bash

set -euo pipefail

# Mirrors the previous .github/workflows/ci.yml: install deps, run JS+Swift
# tests, build, and (only on main, only when the package.json version is new)
# `npm publish` to GitHub Packages. Tag builds run tests + build but never
# publish — those are handled by the CLI release step.

echo "--- :yarn: install JS deps"
# The Buildkite Mac agents ship Node but leave corepack disabled, so `yarn`
# isn't on PATH out of the box. Enabling corepack activates the version pinned
# by `packageManager` in package.json.
corepack enable
yarn install --immutable --inline-builds

echo "--- :wrench: prep Xcode for cached derived data"
# Same tweak the GHA workflow used; helps when the agent reuses derived data
# across builds.
defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES

echo "--- :jest: run TypeScript tests"
yarn test:js

echo "--- :swift: run Swift tests"
yarn test:swift

# Decide whether to publish to GH Packages.
# Match GHA: only on main, only when the package.json version isn't already
# on the registry, and never on tag builds (tags drive the CLI release).
should_publish=false
if [ "${BUILDKITE_BRANCH:-}" = "main" ] && [ -z "${BUILDKITE_TAG:-}" ]; then
  version="$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')"
  if npm show "@beeper/platform-imessage@${version}" >/dev/null 2>&1; then
    echo "--- :information_source: version ${version} already on registry; skipping publish"
  else
    should_publish=true
  fi
fi

# Manual override — equivalent to GHA's `workflow_dispatch` `publishing=true`.
# Set via build env var (e.g. via the "New Build" dialog or BK API).
if [ "${PUBLISHING:-false}" = "true" ]; then
  should_publish=true
fi

if "$should_publish"; then
  echo "--- :rocket: build and publish to GH Packages"
  CI_PUBLISHING=true npm publish
else
  echo "--- :hammer: build (no publish)"
  CI_PUBLISHING=false yarn build
fi
