import { spawn } from 'node:child_process'
import { setTimeout as sleep } from 'node:timers/promises'

import type { PlatformAPI } from '@textshq/platform-sdk'

import type { NativeMacPermissionAuthStatus, NativeMacPermissionAuthType } from '../IMessage/lib'

type AuthApi = Pick<PlatformAPI, 'getAsset'>

export const AUTHORIZATION_REQUIREMENTS = ['accessibility', 'contacts', 'full-disk-access'] as const

// `automation` is not preflight-checkable: macOS does not expose its status
// without triggering the Apple Events prompt. It remains a valid target for
// `authorize` and is included when running `authorize all`.
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
  | 'askForContactsAccess'
  | 'askForFullDiskAccess'
  | 'canAccessMessagesDir'
  | 'confirmUNCPrompt'
  | 'getAccessibilityAuthStatus'
  | 'getContactsAuthStatus'
  | 'getFullDiskAccessAuthStatus'
  | 'isMessagesAppSetup'
  | 'startSysPrefsOnboarding'
  | 'stopSysPrefsOnboarding'

type Deps = { api: AuthApi }

async function loadDeps(api: AuthApi): Promise<Deps> {
  return { api }
}

async function callProxied<T>({ api }: Deps, method: ProxiedAuthMethod): Promise<T> {
  const response = await api.getAsset?.(undefined, 'proxied', method)
  return JSON.parse(response as string) as T
}

const statusTitles: Record<CliAuthorizationStatusKey, string> = {
  accessibility: 'Accessibility',
  contacts: 'Contacts',
  'full-disk-access': 'Full Disk Access',
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
  deps: Deps,
  authType: NativeMacPermissionAuthType,
  durationMs = 120_000,
  intervalMs = 250,
): Promise<boolean> {
  const deadline = Date.now() + durationMs
  do {
    if (await getAuthStatus(deps, authType) === 'authorized') return true
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

async function getAuthStatus(deps: Deps, authType: NativeMacPermissionAuthType): Promise<NativeMacPermissionAuthStatus> {
  const methods = {
    accessibility: 'getAccessibilityAuthStatus',
    contacts: 'getContactsAuthStatus',
    'full-disk-access': 'getFullDiskAccessAuthStatus',
  } as const satisfies Record<NativeMacPermissionAuthType, ProxiedAuthMethod>
  return callProxied<NativeMacPermissionAuthStatus>(deps, methods[authType])
}

async function getAuthorizationStatuses(
  deps: Deps,
  only?: readonly CliAuthorizationStatusKey[],
): Promise<CliAuthorizationStatus[]> {
  const wants = (key: CliAuthorizationStatusKey) => !only || only.includes(key)
  const [axStatus, contactsStatus, fullDiskAccessStatus] = await Promise.all([
    wants('accessibility') ? getAuthStatus(deps, 'accessibility') : undefined,
    wants('contacts') ? getAuthStatus(deps, 'contacts') : undefined,
    wants('full-disk-access') || wants('messages-app-setup') ? getAuthStatus(deps, 'full-disk-access') : undefined,
  ])

  const statuses: CliAuthorizationStatus[] = []

  if (wants('accessibility')) {
    const ok = axStatus === 'authorized'
    statuses.push(makeStatus('accessibility', ok,
      ok ? 'Your current Terminal app can control Messages.app.'
         : 'Enable your current Terminal app in System Settings > Privacy & Security > Accessibility.'))
  }

  if (wants('contacts')) {
    const ok = contactsStatus === 'authorized'
    statuses.push(makeStatus('contacts', ok,
      ok ? 'Contacts lookups are available.'
         : 'Allow Contacts access if you want contact-name lookups from the CLI.'))
  }

  if (wants('full-disk-access')) {
    const ok = fullDiskAccessStatus === 'authorized'
    statuses.push(makeStatus('full-disk-access', ok,
      ok ? 'The CLI can read protected Messages settings.'
         : 'Enable your current Terminal app in System Settings > Privacy & Security > Full Disk Access.'))
  }

  if (wants('messages-app-setup')) {
    const authorized = fullDiskAccessStatus === 'authorized'
    const setup = authorized && await callProxied<boolean>(deps, 'isMessagesAppSetup').catch(() => false)
    statuses.push(makeStatus('messages-app-setup', setup,
      !authorized ? 'Grant Full Disk Access first to verify whether Messages.app is set up.'
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
  if (requirements.includes('full-disk-access') && !await callProxied<boolean>(deps, 'canAccessMessagesDir')) {
    throw new Error('Full Disk Access is enabled, but the Messages database is unavailable. Open Messages.app and finish setup, then restart your Terminal app if needed.')
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
  await callProxied<void>(deps, 'askForContactsAccess').catch(() => undefined)
  await pollForAuthorization(deps, 'contacts', 2_000)
}

async function authorizeFullDiskAccess(deps: Deps) {
  await callProxied<void>(deps, 'askForFullDiskAccess')
  await pollForAuthorization(deps, 'full-disk-access')
}

async function authorizeAutomation(deps: Deps): Promise<boolean> {
  if (await getAuthStatus(deps, 'accessibility') === 'authorized') {
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
    case 'full-disk-access': await authorizeFullDiskAccess(deps)
  }
}

function resolveTarget(target: CliAuthorizationTarget): {
  checkable: readonly CliAuthorizationRequirement[]
  printKeys: readonly CliAuthorizationStatusKey[]
} {
  switch (target) {
    case 'all':        return { checkable: AUTHORIZATION_REQUIREMENTS, printKeys: [...AUTHORIZATION_REQUIREMENTS, 'automation', 'messages-app-setup'] }
    case 'automation': return { checkable: [], printKeys: ['automation'] }
    case 'full-disk-access': return { checkable: [target], printKeys: [target, 'messages-app-setup'] }
    default:           return { checkable: [target], printKeys: [target] }
  }
}

// Granting FDA also makes the Messages database available. Refresh setup
// readiness so an earlier denial does not leave a stale incomplete status.
const keysImpactedBy = (requirement: CliAuthorizationRequirement): readonly CliAuthorizationStatusKey[] => {
  if (requirement === 'full-disk-access') return ['full-disk-access', 'messages-app-setup']
  return [requirement]
}

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
  if (printKeys.includes('messages-app-setup') && !findStatus(statuses, 'messages-app-setup')?.authorized) {
    throw new Error('Full Disk Access is enabled, but Messages.app setup could not be verified. Open Messages.app and finish setup, then restart your Terminal app if needed.')
  }
}
