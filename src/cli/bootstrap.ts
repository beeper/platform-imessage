import path from 'node:path'

import * as platformTestLib from '@textshq/platform-test-lib'
import type { TextsNodeGlobals } from '@textshq/platform-sdk/dist/TextsGlobals'

type InjectGlobals = (isDev: boolean, isLoggingEnabled: boolean, userDataDirPath: string) => void

declare global {
  // eslint-disable-next-line no-var, vars-on-top
  var texts: TextsNodeGlobals
}

// platform-test-lib is CJS; Node's ESM-from-CJS interop and different bundler
// conventions expose the default export at varying nesting depths, so unwrap
// until we hit the function.
function unwrapDefault<T>(value: unknown): T {
  let current: any = value
  while (current && typeof current !== 'function' && 'default' in current) {
    current = current.default
  }
  return current as T
}
const injectGlobals = unwrapDefault<InjectGlobals>(platformTestLib)

// the CLI is bundled to a single .mjs at the repo root, so import.meta.dirname
// is the repo root at runtime
const REPO_ROOT = import.meta.dirname

export function installCliGlobals(isDev: boolean, isLoggingEnabled: boolean) {
  injectGlobals(isDev, isLoggingEnabled, REPO_ROOT)
  globalThis.texts = {
    ...globalThis.texts,
    getBinariesDirPath() {
      return path.join(REPO_ROOT, 'binaries')
    },
  } satisfies TextsNodeGlobals
}
