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
tag=""
if [ "${BUILDKITE_BRANCH:-}" = "main" ] && [ -z "${BUILDKITE_TAG:-}" ]; then
  version="$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')"
  if npm show "@beeper/platform-imessage@${version}" >/dev/null 2>&1; then
    echo "--- :information_source: version ${version} already on registry; skipping publish"
  else
    should_publish=true
  fi

  previous_version=""
  if git cat-file -e "${BUILDKITE_COMMIT}^:package.json" 2>/dev/null; then
    previous_version="$(git show "${BUILDKITE_COMMIT}^:package.json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')"
  fi

  if [ "$previous_version" != "$version" ]; then
    tag="v${version}"
    if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
      echo "--- :information_source: tag ${tag} already exists; skipping tag creation"
      tag=""
    fi
  else
    echo "--- :information_source: package version unchanged; skipping tag creation"
  fi
fi

# Manual override.
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

if [ -n "$tag" ]; then
  echo "--- :label: create version tag ${tag}"

  local_tag_target="$(git rev-list -n 1 "refs/tags/${tag}" 2>/dev/null || true)"
  if [ -n "$local_tag_target" ] && [ "$local_tag_target" != "$BUILDKITE_COMMIT" ]; then
    printf >&2 "local tag %s already points at %s, expected %s\n" "$tag" "$local_tag_target" "$BUILDKITE_COMMIT"
    exit 1
  fi

  if [ -z "$local_tag_target" ]; then
    git tag "$tag" "$BUILDKITE_COMMIT"
  fi

  git push origin "refs/tags/${tag}"
fi
