import { app } from 'electron'
import * as fs from 'node:fs/promises'
import * as os from 'node:os'
import * as path from 'node:path'
import { clearLine, cursorTo } from 'node:readline'
import * as readline from 'node:readline/promises'
import { inspect, parseArgs } from 'node:util'
import { setTimeout as sleep } from 'node:timers/promises'

import {
  ActivityType,
  InboxName,
} from '@textshq/platform-sdk'
import type {
  ClientContext,
  OnServerEventCallback,
  PaginationArg,
  PlatformAPI,
  SerializedSession,
  ServerEvent,
} from '@textshq/platform-sdk'
import { supportedReactions } from '../common-constants'
import { AUTHORIZATION_TARGETS, runAuthorizationFlow, runPreflightAuthCheck } from './auth'
import type { CliAuthorizationRequirement } from './auth'

const KEEP_ALIVE_FLAG = '--stay-open'
const DATA_DIR_FLAG = '--data-dir'
const NO_EVENTS_FLAG = '--no-events'
const VERBOSE_FLAG = '--verbose'
const MESSAGES_INSTANCE_FLAG = '--messages-instance'
const HIDE_MESSAGES_APP_FLAG = '--hide-messages-app'
const SHELL_COMMAND = 'shell'
const HELP_COMMAND = 'help'
const PROMPT = 'imessage> '
const SHUTDOWN_TIMEOUT_MS = 2_000
const GLOBAL_CLI_OPTIONS = {
  'data-dir': { type: 'string' },
  'messages-instance': { type: 'string' },
  'hide-messages-app': { type: 'string' },
  'stay-open': { type: 'boolean' },
  'no-events': { type: 'boolean' },
  verbose: { type: 'boolean' },
  help: { type: 'boolean', short: 'h' },
} as const

const historyFilePath = path.resolve(import.meta.dirname, '.cli.history.json')

const CATEGORIES = ['General', 'Message', 'Chat'] as const
type Category = typeof CATEGORIES[number]

type BackendMethodName = {
  [K in keyof PlatformAPI]-?: NonNullable<PlatformAPI[K]> extends (...args: any[]) => any ? K : never
}[keyof PlatformAPI]

type RunnerOptions = {
  commandArgs: string[]
  customDataDir?: string
  keepAlive: boolean
  loggingEnabled: boolean
  messagesInstanceMode: 'default' | 'puppet'
  shouldAutoHideMessages: boolean
  subscribeToEvents: boolean
}

type RunnerState = RunnerOptions & {
  dataDirPath: string
  sessionFilePath: string
}

type CliPlatformAPI = PlatformAPI & {
  startEventPollingFromCurrentState?: () => Promise<void>
}

type CommandDefinition = {
  name: string
  category: Category
  summary: string
  usage: string[]
  examples: string[]
  notes?: string[]
  requiredAuthorization?: CliAuthorizationRequirement[]
  execute: (args: string[], context: InvokeContext) => Promise<void>
}

type InvokeContext = {
  command: CommandDefinition
  getApi: () => Promise<PlatformAPI>
  invokeMethod: (methodName: BackendMethodName, args: unknown[]) => Promise<unknown>
  showHelp: (commandName?: string) => void
  showState: () => void
}

// `supportedReactions` is the shared source of truth for standard reaction keys.
// `laugh` is rendered to clients as "HAHA", but the CLI still documents the accepted emoji alias.
const REACTION_DOCS = Object.entries(supportedReactions).map(([key, reaction]) => ({
  key,
  emoji: key === 'laugh' ? '😂' : reaction.render,
}))

const readHistory = async (): Promise<string[]> =>
  JSON.parse(await fs.readFile(historyFilePath, 'utf8'))

const writeHistory = (history: string[]): Promise<void> =>
  fs.writeFile(historyFilePath, JSON.stringify(history))

function formatEvents(events: ServerEvent[]): string {
  const stamp = new Date().toISOString()
  return `[events ${stamp}] ${inspect(events, { colors: true, depth: 8 })}`
}

function parseCliArgs(argv: string[]): RunnerOptions {
  let commandStartIndex = argv.length
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--') {
      commandStartIndex = index
      break
    }
    if (arg.startsWith('--')) {
      const optionName = arg.slice(2).split('=', 1)[0]
      const option = GLOBAL_CLI_OPTIONS[optionName as keyof typeof GLOBAL_CLI_OPTIONS]
      if (option?.type === 'string' && !arg.includes('=')) index += 1
      if (option) continue
    }
    if (!arg.startsWith('-')) {
      commandStartIndex = index
      break
    }
  }

  const globalArgs = argv.slice(0, commandStartIndex)
  const commandArgsRaw = argv[commandStartIndex] === '--'
    ? argv.slice(commandStartIndex + 1)
    : argv.slice(commandStartIndex)

  const { values } = parseArgs({
    args: globalArgs,
    allowPositionals: true,
    options: GLOBAL_CLI_OPTIONS,
    strict: true,
  })

  const commandArgs = values.help ? [HELP_COMMAND, ...commandArgsRaw] : commandArgsRaw
  const messagesInstanceMode = values['messages-instance'] ?? process.env.IMESSAGE_MESSAGES_INSTANCE_MODE ?? 'default'
  if (messagesInstanceMode !== 'default' && messagesInstanceMode !== 'puppet') {
    throw new Error(`${MESSAGES_INSTANCE_FLAG} must be either "default" or "puppet"`)
  }
  const shouldAutoHideMessages = parseBooleanOption(
    HIDE_MESSAGES_APP_FLAG,
    values['hide-messages-app'] ?? process.env.IMESSAGE_AUTO_HIDE_MESSAGES,
    true,
  )

  return {
    commandArgs,
    customDataDir: values['data-dir'],
    keepAlive: values['stay-open'] ?? false,
    loggingEnabled: values.verbose ?? false,
    messagesInstanceMode,
    shouldAutoHideMessages,
    subscribeToEvents: !(values['no-events'] ?? false),
  }
}

async function ensureRunnerState(options: RunnerOptions): Promise<RunnerState> {
  let dataDirPath: string
  if (options.customDataDir) {
    dataDirPath = path.resolve(options.customDataDir)
    await fs.mkdir(dataDirPath, { recursive: true })
  } else {
    dataDirPath = await fs.mkdtemp(path.join(os.tmpdir(), 'platform-imessage-cli-'))
  }

  return {
    ...options,
    dataDirPath,
    sessionFilePath: path.join(dataDirPath, 'session.json'),
  }
}

async function loadSession(filePath: string): Promise<SerializedSession> {
  return fs.readFile(filePath, 'utf8')
    .then(contents => JSON.parse(contents))
    .catch(() => ({}))
}

async function saveSession(api: PlatformAPI, sessionFilePath: string) {
  const serialized = await api.serializeSession?.()
  if (serialized === undefined) return
  await fs.writeFile(sessionFilePath, JSON.stringify(serialized, null, 2))
}

const accountID = 'default'
async function createPlatformAPI(state: RunnerState) {
  process.env.IMESSAGE_LOGGING_DIR_PATH = state.dataDirPath
  process.env.IMESSAGE_MESSAGES_INSTANCE_MODE = state.messagesInstanceMode
  process.env.IMESSAGE_AUTO_HIDE_MESSAGES = state.shouldAutoHideMessages ? '1' : '0'
  const { default: AppleiMessage } = await import('../api')
  const api = new AppleiMessage(accountID)
  // We do not currently depend on persisted CLI session state, but keeping this
  // load/save path wired up makes it straightforward to resume stateful flows later.
  const session = await loadSession(state.sessionFilePath)
  const context: ClientContext = {
    accountID,
    dataDirPath: state.dataDirPath,
  }
  await api.init(session, context)
  return api
}

function requireExactArgs(command: CommandDefinition, args: string[], count: number) {
  if (args.length !== count) {
    throw new Error(`${command.name} expects ${count} argument${count === 1 ? '' : 's'}.\nusage: ${command.usage[0]}`)
  }
}

function requireMinArgs(command: CommandDefinition, args: string[], count: number) {
  if (args.length < count) {
    throw new Error(`${command.name} expects at least ${count} argument${count === 1 ? '' : 's'}.\nusage: ${command.usage[0]}`)
  }
}

function requireStringOption(command: CommandDefinition, optionName: string, value: string | undefined): string {
  const text = value?.trim()
  if (!text) {
    throw new Error(`${command.name} requires ${optionName}.\nusage: ${command.usage[0]}`)
  }
  return text
}

function joinText(command: CommandDefinition, tokens: string[], startIndex: number): string {
  const text = tokens.slice(startIndex).join(' ').trim()
  if (!text) throw new Error(`${command.name} requires text content.\nusage: ${command.usage[0]}`)
  return text
}

function parseBooleanOption(name: string, value: string | undefined, defaultValue: boolean): boolean {
  if (value == null) return defaultValue
  switch (value.toLowerCase()) {
  case 'true':
  case '1':
  case 'yes':
    return true
  case 'false':
  case '0':
  case 'no':
    return false
  default:
    throw new Error(`${name} must be true or false`)
  }
}

function parsePaginationArgs(command: CommandDefinition, args: string[], positionalCount: number): { positionals: string[], pagination?: PaginationArg } {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: {
      after: { type: 'string' },
      before: { type: 'string' },
    },
    strict: true,
  })

  requireExactArgs(command, positionals, positionalCount)

  const usage = `usage: ${command.usage[0]}`
  const readCursor = (raw: string | undefined, flag: 'after' | 'before') => {
    if (raw == null) return undefined
    const trimmed = raw.trim()
    if (!trimmed) throw new Error(`${command.name} requires a cursor after --${flag}.\n${usage}`)
    return trimmed
  }

  const after = readCursor(values.after, 'after')
  const before = readCursor(values.before, 'before')
  if (after && before) throw new Error(`${command.name} accepts only one of --after or --before.\n${usage}`)

  const pagination: PaginationArg | undefined = after ? { cursor: after, direction: 'after' }
    : before ? { cursor: before, direction: 'before' }
    : undefined

  return { positionals, pagination }
}

function tokenizeInput(input: string): string[] {
  const tokens: string[] = []
  let current = ''
  let quote: '"' | "'" | null = null

  const pushCurrent = () => {
    if (!current) return
    tokens.push(current)
    current = ''
  }

  for (let index = 0; index < input.length; index += 1) {
    const char = input[index]

    if (char === '\\') {
      const nextChar = input[index + 1]
      if (nextChar) {
        current += nextChar
        index += 1
      }
      continue
    }

    if (quote) {
      if (char === quote) quote = null
      else current += char
      continue
    }

    if (char === '"' || char === "'") {
      quote = char
      continue
    }

    if (/\s/.test(char)) {
      pushCurrent()
      continue
    }

    current += char
  }

  if (quote) throw new Error(`unterminated ${quote} quote`)

  pushCurrent()
  return tokens
}

function formatGlobalFlags() {
  return [
    `  ${DATA_DIR_FLAG} PATH     Store CLI state under PATH instead of a temp directory`,
    `  ${MESSAGES_INSTANCE_FLAG} MODE  Use "default" or "puppet" Messages instance mode`,
    `  ${HIDE_MESSAGES_APP_FLAG} BOOL  Whether to automatically hide or move the Messages app/window`,
    `  ${NO_EVENTS_FLAG}        Do not subscribe to server events after running commands`,
    `  ${KEEP_ALIVE_FLAG}       Run one command, then stay open in the interactive shell`,
    `  ${VERBOSE_FLAG}          Enable verbose logging`,
  ]
}

const reactionNotes = [
  `Supported standard keys: ${REACTION_DOCS.map(r => `${r.key} (${r.emoji})`).join(', ')}`,
  'Sticker reactions are not exposed in this CLI.',
]

const UNDO_SEND_TIME_LIMIT_MINUTES = 2

function reactionCommand(
  name: 'react' | 'unreact',
  method: 'addReaction' | 'removeReaction',
  verb: string,
): CommandDefinition {
  return {
    name,
    category: 'Message',
    summary: `${verb} a reaction ${name === 'react' ? 'to' : 'from'} a message using a standard key or emoji.`,
    usage: [`${name} CHAT_ID MESSAGE_ID REACTION`],
    examples: [
      `${name} any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 heart`,
      `${name} any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 ❤️`,
    ],
    notes: reactionNotes,
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 3)
      await context.invokeMethod(method, [args[0], args[1], args[2]])
    },
  }
}

function muteCommand(name: 'mute' | 'unmute', mutedUntil: 'forever' | null): CommandDefinition {
  return {
    name,
    category: 'Chat',
    summary: name === 'mute' ? 'Mute a chat indefinitely.' : 'Unmute a chat.',
    usage: [`${name} CHAT_ID`],
    examples: [`${name} any;-;sjobs@apple.com`],
    requiredAuthorization: ['messages-data', 'accessibility'],
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 1)
      await context.invokeMethod('updateThread', [args[0], { mutedUntil }])
    },
  }
}

const READ_ONLY_AUTH: CliAuthorizationRequirement[] = ['messages-data']
const MUTATING_AUTH: CliAuthorizationRequirement[] = ['messages-data', 'accessibility']

const commandDefinitions: CommandDefinition[] = [
  {
    name: HELP_COMMAND,
    category: 'General',
    summary: 'Show top-level help or help for a specific command.',
    usage: ['help', 'help COMMAND'],
    examples: ['help', 'help send'],
    execute: async (args, context) => {
      if (args.length > 1) throw new Error('usage: help [COMMAND]')
      context.showHelp(args[0])
    },
  },
  {
    name: SHELL_COMMAND,
    category: 'General',
    summary: 'Open the interactive shell (also the default when no command is given).',
    usage: ['shell'],
    examples: ['shell'],
    execute: async () => {},
  },
  {
    name: 'state',
    category: 'General',
    summary: 'Print the current CLI runtime state and data paths.',
    usage: ['state'],
    examples: ['state'],
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 0)
      context.showState()
    },
  },
  {
    name: 'current-user',
    category: 'General',
    summary: 'Show the current iMessage identity known to the platform.',
    usage: ['current-user'],
    examples: ['current-user'],
    requiredAuthorization: READ_ONLY_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 0)
      await context.invokeMethod('getCurrentUser', [])
    },
  },
  {
    name: 'open-settings',
    category: 'General',
    summary: 'Open the settings window.',
    usage: ['open-settings'],
    examples: ['open-settings'],
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 0)
      const api = await context.getApi()
      await api.getAsset!(undefined, 'proxied', 'revealSettings')
    },
  },
  {
    name: 'authorize',
    category: 'General',
    summary: 'Inspect or request CLI permissions for Accessibility, Contacts, Messages Data, and Automation.',
    usage: ['authorize', 'authorize TARGET'],
    examples: ['authorize', 'authorize accessibility', 'authorize all'],
    notes: [`Targets: ${AUTHORIZATION_TARGETS.join(', ')}.`],
    execute: async (args, context) => {
      if (args.length > 1) throw new Error(`usage: authorize [${AUTHORIZATION_TARGETS.join('|')}]`)
      await runAuthorizationFlow(args[0], await context.getApi())
    },
  },
  {
    name: 'threads',
    category: 'Chat',
    summary: 'List chats from the normal inbox.',
    usage: ['threads [--before CURSOR|--after CURSOR]'],
    examples: [
      'threads',
      'threads --before 725506281967999900',
    ],
    notes: [
      'Use `oldestCursor` from a result page with --before to fetch older chats.',
      'Use --after CURSOR to fetch chats newer than that cursor.',
    ],
    requiredAuthorization: READ_ONLY_AUTH,
    execute: async (args, context) => {
      const { pagination } = parsePaginationArgs(context.command, args, 0)
      await context.invokeMethod('getThreads', [InboxName.NORMAL, pagination])
    },
  },
  {
    name: 'thread',
    category: 'Chat',
    summary: 'Fetch a single chat by chat ID.',
    usage: ['thread CHAT_ID'],
    examples: ['thread any;-;sjobs@apple.com'],
    requiredAuthorization: READ_ONLY_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 1)
      await context.invokeMethod('getThread', [args[0]])
    },
  },
  {
    name: 'messages',
    category: 'Message',
    summary: 'List messages in a chat.',
    usage: ['messages CHAT_ID [--before CURSOR|--after CURSOR]'],
    examples: [
      'messages any;-;sjobs@apple.com',
      'messages any;-;sjobs@apple.com --before 725506281967999900',
    ],
    notes: [
      'Use a message item `cursor` with --before to fetch older messages.',
      'Use --after CURSOR to fetch messages newer than that cursor.',
    ],
    requiredAuthorization: READ_ONLY_AUTH,
    execute: async (args, context) => {
      const { positionals, pagination } = parsePaginationArgs(context.command, args, 1)
      await context.invokeMethod('getMessages', [positionals[0], pagination])
    },
  },
  {
    name: 'message',
    category: 'Message',
    summary: 'Fetch a single message by chat ID and message ID.',
    usage: ['message CHAT_ID MESSAGE_ID'],
    examples: ['message any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678'],
    requiredAuthorization: READ_ONLY_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 2)
      await context.invokeMethod('getMessage', [args[0], args[1]])
    },
  },
  {
    name: 'search',
    category: 'Message',
    summary: 'Search messages by text.',
    usage: ['search QUERY'],
    examples: ['search hello', 'search "project status"'],
    requiredAuthorization: READ_ONLY_AUTH,
    execute: async (args, context) => {
      requireMinArgs(context.command, args, 1)
      await context.invokeMethod('searchMessages', [args.join(' ')])
    },
  },
  {
    name: 'create-thread',
    category: 'Message',
    summary: 'Create or resolve a chat for one or more recipients and send the initial message.',
    usage: [
      'create-thread RECIPIENT... --message TEXT',
    ],
    examples: [
      'create-thread sjobs@apple.com --message "hello from cli"',
      'create-thread +15551234567 +15557654321 --message "group kickoff"',
    ],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      const { values, positionals } = parseArgs({
        args,
        allowPositionals: true,
        options: { message: { type: 'string' } },
        strict: true,
      })
      requireMinArgs(context.command, positionals, 1)
      const message = requireStringOption(context.command, '--message TEXT', values.message)
      await context.invokeMethod('createThread', [positionals, undefined, message])
    },
  },
  {
    name: 'send',
    category: 'Message',
    summary: 'Send a text message to a chat.',
    usage: ['send CHAT_ID_OR_EMAIL TEXT'],
    examples: [
      'send sjobs@apple.com "hello from cli"',
      'send any;-;sjobs@apple.com "hello from cli"',
      'send any;-;+14155551234 "quoted shell text works"',
    ],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireMinArgs(context.command, args, 2)
      await context.invokeMethod('sendMessage', [args[0], { text: joinText(context.command, args, 1) }])
    },
  },
  {
    name: 'reply',
    category: 'Message',
    summary: 'Reply to a specific message with text.',
    usage: ['reply CHAT_ID MESSAGE_ID TEXT'],
    examples: [
      'reply any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 "sounds good"',
    ],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireMinArgs(context.command, args, 3)
      await context.invokeMethod(
        'sendMessage',
        [args[0], { text: joinText(context.command, args, 2) }, { quotedMessageID: args[1] }],
      )
    },
  },
  {
    name: 'send-file',
    category: 'Message',
    summary: 'Send a file attachment to a chat.',
    usage: ['send-file CHAT_ID_OR_EMAIL FILE'],
    examples: ['send-file sjobs@apple.com ./image.png', 'send-file any;-;sjobs@apple.com ./image.png'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 2)
      await context.invokeMethod('sendMessage', [args[0], { filePath: path.resolve(args[1]) }])
    },
  },
  {
    name: 'reply-file',
    category: 'Message',
    summary: 'Reply to a specific message with a file attachment.',
    usage: ['reply-file CHAT_ID MESSAGE_ID FILE'],
    examples: [
      'reply-file any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 ./document.pdf',
    ],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 3)
      await context.invokeMethod(
        'sendMessage',
        [args[0], { filePath: path.resolve(args[2]) }, { quotedMessageID: args[1] }],
      )
    },
  },
  {
    name: 'edit',
    category: 'Message',
    summary: 'Edit a previously sent message.',
    usage: ['edit CHAT_ID MESSAGE_ID TEXT'],
    examples: [
      'edit any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 "updated text"',
    ],
    notes: ['Message editing is only supported on macOS Ventura or later.'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireMinArgs(context.command, args, 3)
      await context.invokeMethod(
        'editMessage',
        [args[0], args[1], { text: joinText(context.command, args, 2) }],
      )
    },
  },
  {
    name: 'undo-send',
    category: 'Message',
    summary: 'Undo send for a previously sent message.',
    usage: ['undo-send CHAT_ID MESSAGE_ID'],
    examples: [
      'undo-send any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678',
    ],
    notes: [`Undo send is only supported on macOS Ventura or later and must be used within ${UNDO_SEND_TIME_LIMIT_MINUTES} minutes of sending.`],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 2)
      await context.invokeMethod('deleteMessage', [args[0], args[1]])
    },
  },
  reactionCommand('react', 'addReaction', 'Add'),
  reactionCommand('unreact', 'removeReaction', 'Remove'),
  {
    name: 'mark-read',
    category: 'Chat',
    summary: 'Mark a chat as read.',
    usage: ['mark-read CHAT_ID'],
    examples: ['mark-read any;-;sjobs@apple.com'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 1)
      await context.invokeMethod('sendReadReceipt', [args[0]])
    },
  },
  {
    name: 'mark-unread',
    category: 'Chat',
    summary: 'Mark a chat as unread.',
    usage: ['mark-unread CHAT_ID'],
    examples: ['mark-unread any;-;sjobs@apple.com'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 1)
      await context.invokeMethod('markAsUnread', args)
    },
  },
  {
    name: 'delete-thread',
    category: 'Chat',
    summary: 'Delete a chat from Messages.',
    usage: ['delete-thread CHAT_ID'],
    examples: ['delete-thread any;-;sjobs@apple.com'],
    notes: ['This mutates real Messages state.'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 1)
      await context.invokeMethod('deleteThread', args)
    },
  },
  {
    name: 'notify-anyway',
    category: 'Chat',
    summary: 'Trigger the "notify anyway" action for a chat.',
    usage: ['notify-anyway CHAT_ID'],
    examples: ['notify-anyway any;-;sjobs@apple.com'],
    notes: ['This mutates real Messages state and may require accessibility permissions.'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 1)
      await context.invokeMethod('notifyAnyway', args)
    },
  },
  muteCommand('mute', 'forever'),
  muteCommand('unmute', null),
  {
    name: 'select-thread',
    category: 'Chat',
    summary: 'Select a chat and start the chat-activity watcher.',
    usage: ['select-thread CHAT_ID'],
    examples: ['select-thread any;-;sjobs@apple.com'],
    notes: ['This is an advanced command and may require accessibility permissions.'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 1)
      await context.invokeMethod('onThreadSelected', args)
    },
  },
  {
    name: 'typing',
    category: 'Chat',
    summary: 'Send typing on/off status for a chat.',
    usage: ['typing CHAT_ID on|off'],
    examples: [
      'typing any;-;sjobs@apple.com on',
      'typing any;-;sjobs@apple.com off',
    ],
    notes: ['This is an advanced command and may require accessibility permissions.'],
    requiredAuthorization: MUTATING_AUTH,
    execute: async (args, context) => {
      requireExactArgs(context.command, args, 2)
      const activityByMode: Record<string, ActivityType> = {
        on: ActivityType.TYPING,
        off: ActivityType.NONE,
      }
      const activity = activityByMode[args[1]]
      if (activity === undefined) throw new Error(`usage: ${context.command.usage[0]}`)
      await context.invokeMethod('sendActivityIndicator', [activity, args[0]])
    },
  },
]

const commandMap = new Map(commandDefinitions.map(command => [command.name, command]))

function printTopLevelHelp() {
  const grouped = new Map<Category, CommandDefinition[]>()
  commandDefinitions.forEach(command => {
    const entries = grouped.get(command.category) ?? []
    entries.push(command)
    grouped.set(command.category, entries)
  })

  const sections = [
    'platform-imessage CLI',
    '',
    'Usage:',
    '  cli [global options]',
    '  cli COMMAND [ARGS...]',
    '',
    'Bare launch (or `shell`) opens the interactive shell.',
    '',
    'Global options:',
    ...formatGlobalFlags(),
    '',
  ]

  CATEGORIES.forEach(category => {
    const commands = grouped.get(category)
    if (!commands?.length) return
    sections.push(`${category} commands:`)
    commands.forEach(command => {
      sections.push(`  ${command.name.padEnd(16)} ${command.summary}`)
    })
    sections.push('')
  })

  sections.push('Run `help COMMAND` for detailed usage and examples.')
  console.log(sections.join('\n'))
}

function printCommandHelp(command: CommandDefinition) {
  const lines = [
    command.name,
    '',
    command.summary,
    '',
    'Usage:',
    ...command.usage.map(usage => `  ${usage}`),
    '',
    'Examples:',
    ...command.examples.map(example => `  ${example}`),
  ]

  if (command.notes?.length) {
    lines.push('', 'Notes:', ...command.notes.map(note => `  ${note}`))
  }

  console.log(lines.join('\n'))
}

async function main(runnerOptions: RunnerOptions) {
  const state = await ensureRunnerState(runnerOptions)
  let apiPromise: Promise<CliPlatformAPI> | undefined
  let nextCallID = 1
  let rl: readline.Interface | undefined
  let shuttingDown = false
  let eventsStarted = false

  // readline doesn't reprint the prompt after external writes, so we redraw manually
  const printAboveInput = (message: string) => {
    if (!process.stdout.isTTY || !rl) {
      console.log(message)
      return
    }
    const { line, cursor } = rl
    cursorTo(process.stdout, 0)
    clearLine(process.stdout, 0)
    process.stdout.write(`${message}\n${PROMPT}${line}`)
    cursorTo(process.stdout, PROMPT.length + cursor)
  }

  const onEvent: OnServerEventCallback = events => {
    if (!events.length) return
    printAboveInput(formatEvents(events))
  }

  const getApi = async (): Promise<CliPlatformAPI> => {
    apiPromise ??= createPlatformAPI(state)
    return apiPromise
  }

  async function ensureEventSubscription(api: CliPlatformAPI) {
    if (eventsStarted || !state.subscribeToEvents) return
    eventsStarted = true
    await Promise.resolve(api.subscribeToEvents(onEvent)).catch((error: unknown) => {
      console.error('event subscription failed:', error)
    })
    await Promise.resolve(api.startEventPollingFromCurrentState?.()).catch((error: unknown) => {
      console.error('event polling startup failed:', error)
    })
  }

  async function shutdown(api?: PlatformAPI) {
    if (shuttingDown) return
    shuttingDown = true
    // brief drain window so async work triggered by the command can settle before dispose tears everything down
    if (api) await sleep(300)
    rl?.close()
    rl = undefined
    // hard-exit fallback in case dispose hangs on a stuck native handle
    const fallback = setTimeout(() => process.exit(0), SHUTDOWN_TIMEOUT_MS).unref()
    try {
      if (api) {
        await saveSession(api, state.sessionFilePath).catch(error => {
          console.error('saveSession failed:', error)
        })
        await Promise.resolve(api.dispose()).catch(error => {
          console.error('api.dispose failed:', error)
        })
      }
      if (!state.customDataDir) {
        await fs.rm(state.dataDirPath, { recursive: true, force: true }).catch(() => {})
      }
    } finally {
      console.log('Exiting...')
      clearTimeout(fallback)
      app.exit()
    }
  }

  const onSignal = async () => {
    const api = await apiPromise?.catch(() => undefined)
    await shutdown(api)
  }
  process.on('SIGINT', onSignal)
  process.on('SIGTERM', onSignal)

  async function invokeMethod(commandName: string, methodName: BackendMethodName, args: unknown[]) {
    const api = await getApi()
    await ensureEventSubscription(api)
    const method = api[methodName] as ((...methodArgs: unknown[]) => Promise<unknown>) | undefined
    if (!method) throw new Error(`PlatformAPI method "${methodName}" is not available`)

    const id = String(nextCallID).padStart(5, '0')
    nextCallID += 1
    console.log(`[${id}] call ${commandName}`, inspect(args, { colors: true, depth: 8 }))

    const before = performance.now()
    try {
      const result = await method.apply(api, args)
      console.log(
        `[${id}] ok ${commandName} (${(performance.now() - before).toFixed(3)}ms)`,
        inspect(result, { colors: true, depth: 8 }),
      )
      return result
    } catch (error) {
      console.error(
        `[${id}] failed ${commandName} (${(performance.now() - before).toFixed(3)}ms)`,
        error,
      )
      throw error
    }
  }

  function showHelp(commandName?: string) {
    if (!commandName) {
      printTopLevelHelp()
      return
    }
    const command = commandMap.get(commandName)
    if (!command) throw new Error(`unknown command: "${commandName}"`)
    printCommandHelp(command)
  }

  function showState() {
    console.log(inspect({
      dataDirPath: state.dataDirPath,
      sessionFilePath: state.sessionFilePath,
      subscribeToEvents: state.subscribeToEvents,
      loggingEnabled: state.loggingEnabled,
      messagesInstanceMode: state.messagesInstanceMode,
      shouldAutoHideMessages: state.shouldAutoHideMessages,
    }, { colors: true, depth: 4 }))
  }

  async function runParsedCommand(name: string, args: string[]): Promise<void> {
    const command = commandMap.get(name)
    if (!command) throw new Error(`unknown command: "${name}"`)

    if (args.includes('--help') || args.includes('-h')) {
      printCommandHelp(command)
      return
    }

    const context: InvokeContext = {
      command,
      getApi,
      invokeMethod: (methodName, methodArgs) => invokeMethod(command.name, methodName, methodArgs),
      showHelp,
      showState,
    }

    if (command.requiredAuthorization?.length) {
      await runPreflightAuthCheck(command.name, command.requiredAuthorization, await getApi())
    }

    await command.execute(args, context)
  }

  if (runnerOptions.commandArgs.length) {
    const [name, ...args] = runnerOptions.commandArgs
    if (name !== SHELL_COMMAND) {
      await runParsedCommand(name, args)
      if (!state.keepAlive) {
        const api = await apiPromise
        await shutdown(api)
        return
      }
    }
  }

  rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    historySize: 1_000,
    tabSize: 2,
    history: await readHistory().catch(() => []),
    completer: linePartial => [[...commandMap.keys()].filter(command => command.startsWith(linePartial)), linePartial],
  })

  rl.on('history', history => {
    void writeHistory(history)
  })

  while (true) {
    let input: string
    try {
      input = await rl.question(PROMPT)
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code === 'ERR_USE_AFTER_CLOSE') {
        await shutdown(await apiPromise)
        return
      }
      throw error
    }

    const trimmed = input.trim()
    if (!trimmed) continue
    if (/^(q|quit|exit)$/.test(trimmed)) {
      await shutdown(await apiPromise)
      return
    }

    try {
      const tokens = tokenizeInput(trimmed)
      if (!tokens.length) continue
      await runParsedCommand(tokens[0], tokens.slice(1))
    } catch (error) {
      console.error(error)
    }
  }
}

const announceError = (error: unknown, kind = 'exception') => {
  console.error(`UNCAUGHT ${kind.toUpperCase()}:`, error)
}

process.on('uncaughtException', error => {
  announceError(error)
})

process.on('unhandledRejection', error => {
  announceError(error, 'rejection')
})

app.whenReady().then(async () => {
  try {
    await main(parseCliArgs(process.argv.slice(2)))
  } catch (error) {
    announceError(error, 'exception (in main)')
    process.exit(1)
  }
})
