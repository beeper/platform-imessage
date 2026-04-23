import { spawn } from 'node:child_process'
import { setTimeout as sleep } from 'node:timers/promises'

import type { PlatformAPI } from '@textshq/platform-sdk'

type AuthApi = Pick<PlatformAPI, 'getAsset'>

export const AUTHORIZATION_REQUIREMENTS = ['accessibility', 'contacts', 'messages-data'] as const

// `automation` is not preflight-checkable: macOS does not expose its status
// without triggering the Apple Events prompt. It remains a valid target for
// `yarn cli authorize` and is included when running `authorize all`.
export const AUTHORIZATION_TARGETS = ['all', ...AUTHORIZATION_REQUIREMENTS, 'automation'] as const

export type CliAuthorizationRequirement = typeof AUTHORIZATION_REQUIREMENTS[number]
type CliAuthorizationTarget = typeof AUTHORIZATION_TARGETS[number]
type CliAuthorizationStatusKey = CliAuthorizationRequirement | 'automation' | 'messages-app-setup'

type CliAuthorizationStatus = {
  key: CliAuthorizationStatusKey
  title: string
  authorized: boolean
  detail: string
}

type ProxiedAuthMethod =
  | 'askForAutomationAccess'
  | 'askForMessagesDirAccess'
  | 'canAccessMessagesDir'
  | 'confirmUNCPrompt'
  | 'isMessagesAppSetup'
  | 'startSysPrefsOnboarding'
  | 'stopSysPrefsOnboarding'

type MacAuthType = 'accessibility' | 'contacts' | 'full-disk-access'
type MacAuthStatus = 'authorized' | 'denied' | 'restricted' | 'not determined'

type Nmp = {
  askForContactsAccess: () => Promise<unknown>
  askForFullDiskAccess: () => void
  getAuthStatus: (type: MacAuthType) => MacAuthStatus
}

type Deps = { api: AuthApi, nmp: Nmp }

async function loadDeps(api: AuthApi): Promise<Deps> {
  const imported = await import('node-mac-permissions')
  // `node-mac-permissions` is CommonJS, and in the bundled Electron CLI the
  // callable API lives under the default export rather than as named exports.
  const nmp = ('default' in imported ? imported.default : imported) as Nmp
  return { api, nmp }
}

async function callProxied<T>({ api }: Deps, method: ProxiedAuthMethod): Promise<T> {
  const response = await api.getAsset?.(undefined, 'proxied', method)
  return JSON.parse(response as string) as T
}

const statusTitles: Record<CliAuthorizationStatusKey, string> = {
  accessibility: 'Accessibility',
  contacts: 'Contacts',
  'messages-data': 'Messages Data',
  automation: 'Automation',
  'messages-app-setup': 'Messages.app Setup',
}

function parseTarget(value: string | undefined): CliAuthorizationTarget {
  const target = (value ?? 'all').trim() || 'all'
  if ((AUTHORIZATION_TARGETS as readonly string[]).includes(target)) return target as CliAuthorizationTarget
  throw new Error(`unknown authorization target "${target}".\nusage: authorize [${AUTHORIZATION_TARGETS.join('|')}]`)
}

const makeStatus = (
  key: CliAuthorizationStatusKey,
  authorized: boolean,
  detail: string,
): CliAuthorizationStatus => ({ key, title: statusTitles[key], authorized, detail })

const findStatus = (statuses: readonly CliAuthorizationStatus[], key: CliAuthorizationStatusKey) =>
  statuses.find(s => s.key === key)

const formatStatusLine = (status: CliAuthorizationStatus) =>
  `  ${status.authorized ? '[ok]' : '[ ]'} ${status.title} - ${status.detail}`

async function pollForAuthorization(
  { nmp }: Deps,
  authType: Extract<MacAuthType, 'accessibility' | 'contacts'>,
  durationMs = 120_000,
  intervalMs = 250,
): Promise<boolean> {
  const deadline = Date.now() + durationMs
  do {
    if (nmp.getAuthStatus(authType) === 'authorized') return true
    if (Date.now() >= deadline) return false
    await sleep(intervalMs)
  } while (true)
}

// Automation can only be verified by prompting, so its row is synthesized
// separately from `getAuthorizationStatuses` rather than probed.
const automationPendingStatus = () =>
  makeStatus('automation', false, 'Not yet verified — will be requested below.')

const automationResultStatus = (ok: boolean) =>
  makeStatus('automation', ok,
    ok ? 'Apple Events access to Messages.app is available.'
       : 'Automation access was denied or unavailable.')

async function getAuthorizationStatuses(
  deps: Deps,
  only?: readonly CliAuthorizationStatusKey[],
): Promise<CliAuthorizationStatus[]> {
  const wants = (key: CliAuthorizationStatusKey) => !only || only.includes(key)
  const { nmp } = deps
  const statuses: CliAuthorizationStatus[] = []

  if (wants('accessibility')) {
    const ok = nmp.getAuthStatus('accessibility') === 'authorized'
    statuses.push(makeStatus('accessibility', ok,
      ok ? 'Your current Terminal app can control Messages.app.'
         : 'Enable your current Terminal app in System Settings > Privacy & Security > Accessibility.'))
  }

  if (wants('contacts')) {
    const ok = nmp.getAuthStatus('contacts') === 'authorized'
    statuses.push(makeStatus('contacts', ok,
      ok ? 'Contacts lookups are available.'
         : 'Allow Contacts access if you want contact-name lookups from the CLI.'))
  }

  const needMessagesDir = wants('messages-data') || wants('messages-app-setup')
  const messagesDirOk = needMessagesDir ? await callProxied<boolean>(deps, 'canAccessMessagesDir') : false

  if (wants('messages-data')) {
    statuses.push(makeStatus('messages-data', messagesDirOk,
      messagesDirOk ? 'The CLI can read your local Messages data.'
                    : 'The CLI cannot read ~/Library/Messages yet.'))
  }

  if (wants('messages-app-setup')) {
    const setup = messagesDirOk ? await callProxied<boolean>(deps, 'isMessagesAppSetup').catch(() => false) : false
    statuses.push(makeStatus('messages-app-setup', setup,
      !messagesDirOk ? 'Grant Messages Data first to verify whether Messages.app is set up.'
        : setup ? 'Messages.app appears ready to use.'
                : 'Open Messages.app and finish account setup before connecting.'))
  }

  return statuses
}

export async function runPreflightAuthCheck(
  commandName: string,
  requirements: readonly CliAuthorizationRequirement[],
  api: AuthApi,
): Promise<void> {
  const deps = await loadDeps(api)
  const statuses = await getAuthorizationStatuses(deps, requirements)
  for (const requirement of requirements) {
    if (findStatus(statuses, requirement)?.authorized) continue
    console.log(`"${commandName}" needs ${statusTitles[requirement]} access. Requesting...`)
    await authorizeRequirement(requirement, deps)
    const [updated] = await getAuthorizationStatuses(deps, [requirement])
    if (!updated.authorized) throw new Error(`${updated.title} was not granted. ${updated.detail}`)
  }
}

const openSystemSecurityPrefs = (prefPath: string) =>
  spawn('open', [`x-apple.systempreferences:com.apple.preference.security?${prefPath}`], { stdio: 'ignore' })

// Mirrors src/auth/index.tsx: `askForAccessibilityAccess()` is unreliable on
// modern macOS (the system prompt often never appears), so we open Privacy &
// Security → Accessibility directly and let the Swift onboarding helper nudge
// the user through toggling the app.
async function authorizeAccessibility(deps: Deps) {
  openSystemSecurityPrefs('Privacy_Accessibility')
  void callProxied<void>(deps, 'startSysPrefsOnboarding').catch(() => undefined)
  try {
    await pollForAuthorization(deps, 'accessibility')
  } finally {
    void callProxied<void>(deps, 'stopSysPrefsOnboarding').catch(() => undefined)
  }
}

async function authorizeContacts(deps: Deps) {
  await deps.nmp.askForContactsAccess().catch(() => undefined)
  await pollForAuthorization(deps, 'contacts', 2_000)
}

async function authorizeMessagesData(deps: Deps) {
  try {
    await callProxied<void>(deps, 'askForMessagesDirAccess')
  } catch (error) {
    console.log(`  note: Messages Data prompt failed: ${String(error)}`)
  }

  if (!await callProxied<boolean>(deps, 'canAccessMessagesDir')) {
    console.log('  note: Opening Full Disk Access as a fallback.')
    deps.nmp.askForFullDiskAccess()
  }
}

async function authorizeAutomation(deps: Deps): Promise<boolean> {
  if (deps.nmp.getAuthStatus('accessibility') === 'authorized') {
    void callProxied<void>(deps, 'confirmUNCPrompt').catch(error => {
      console.log(`  note: Could not auto-confirm the automation prompt: ${String(error)}`)
    })
  }

  try {
    await callProxied<void>(deps, 'askForAutomationAccess')
    return true
  } catch (error) {
    console.log(`  note: Automation prompt failed: ${String(error)}`)
    return false
  }
}

async function authorizeRequirement(requirement: CliAuthorizationRequirement, deps: Deps) {
  switch (requirement) {
    case 'accessibility': await authorizeAccessibility(deps); return
    case 'contacts':      await authorizeContacts(deps); return
    case 'messages-data': await authorizeMessagesData(deps)
  }
}

function resolveTarget(target: CliAuthorizationTarget): {
  checkable: readonly CliAuthorizationRequirement[]
  printKeys: readonly CliAuthorizationStatusKey[]
} {
  switch (target) {
    case 'all':        return { checkable: AUTHORIZATION_REQUIREMENTS, printKeys: [...AUTHORIZATION_REQUIREMENTS, 'automation', 'messages-app-setup'] }
    case 'automation': return { checkable: [], printKeys: ['automation'] }
    default:           return { checkable: [target], printKeys: [target] }
  }
}

// `messages-app-setup` reads from Messages Data, so refreshing that permission
// must also refresh the readiness row to avoid stale display.
const keysImpactedBy = (requirement: CliAuthorizationRequirement): readonly CliAuthorizationStatusKey[] =>
  requirement === 'messages-data' ? ['messages-data', 'messages-app-setup'] : [requirement]

export async function runAuthorizationFlow(
  rawTarget: string | undefined,
  api: AuthApi,
): Promise<void> {
  const { checkable, printKeys } = resolveTarget(parseTarget(rawTarget))
  const includeAutomation = printKeys.includes('automation')
  const printStatuses = (statuses: CliAuthorizationStatus[]) =>
    statuses.forEach(s => console.log(formatStatusLine(s)))

  const deps = await loadDeps(api)

  const fetched = await getAuthorizationStatuses(deps, printKeys.filter(k => k !== 'automation'))
  let statuses: CliAuthorizationStatus[] = printKeys.map(k =>
    k === 'automation' ? automationPendingStatus() : findStatus(fetched, k)!)

  console.log('Current authorization status:')
  printStatuses(statuses)

  const applyUpdates = (updates: CliAuthorizationStatus[]) => {
    statuses = statuses.map(s => findStatus(updates, s.key) ?? s)
  }

  for (const requirement of checkable) {
    if (findStatus(statuses, requirement)?.authorized) continue

    console.log(`\nRequesting ${statusTitles[requirement]}...`)
    await authorizeRequirement(requirement, deps)

    const refresh = keysImpactedBy(requirement).filter(k => printKeys.includes(k))
    applyUpdates(await getAuthorizationStatuses(deps, refresh))
    const updated = findStatus(statuses, requirement)!
    console.log(formatStatusLine(updated))
    if (!updated.authorized) break
  }

  if (includeAutomation) {
    console.log(`\nRequesting ${statusTitles.automation}...`)
    const result = automationResultStatus(await authorizeAutomation(deps))
    applyUpdates([result])
    console.log(formatStatusLine(result))
  }

  console.log('\nFinal authorization status:')
  printStatuses(statuses)

  const missing = checkable.filter(r => !findStatus(statuses, r)?.authorized)
  if (missing.length) throw new Error(`Authorization incomplete. Missing: ${missing.join(', ')}`)
}
