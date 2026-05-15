#!/usr/bin/env bash

set -euo pipefail

echo "--- :yarn: install JS deps"
# The Buildkite Mac agents ship Node but leave corepack disabled, so `yarn`
# isn't on PATH out of the box. Enabling corepack activates the version pinned
# by `packageManager` in package.json.
corepack enable
yarn install --immutable --inline-builds

echo "--- :jest: run TypeScript tests"
yarn test:js

echo "--- :swift: run Swift tests"
yarn test:swift

# Decide whether to publish to GH Packages.
# Only on main, only when the package.json version isn't already
# on the registry, and never on tag builds (tags drive the CLI release).
should_publish=false
if [ "${BUILDKITE_BRANCH:-}" = "main" ] && [ -z "${BUILDKITE_TAG:-}" ]; then
  if [ "${PUBLISHING:-false}" = "true" ]; then
    # Manual override — equivalent to GHA's `workflow_dispatch` `publishing=true`.
    # Set via build env var (e.g. via the "New Build" dialog or BK API).
    # Scoped to main without a tag, same as the GHA `inputs.publishing` guard.
    should_publish=true
  else
    version="$(scripts/print-package-version)"
    if npm show "@beeper/platform-imessage@${version}" >/dev/null 2>&1; then
      echo "--- :information_source: version ${version} already on registry; skipping publish"
    else
      should_publish=true
    fi
  fi
fi

if "$should_publish"; then
  echo "--- :rocket: build and publish to GH Packages"
  CI_PUBLISHING=true npm publish
else
  echo "--- :hammer: build (no publish)"
  CI_PUBLISHING=false yarn build
fi
