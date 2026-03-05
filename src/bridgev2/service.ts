import { promises as fs } from 'fs'
import path from 'path'
import { ActivityType, InboxName, type ClientContext, type MessageSendOptions, type PaginationArg, type ThreadID } from '@textshq/platform-sdk'

import AppleiMessage from '../api'
import { roomFeatures } from '../capabilities'
import type { BeeperMessage, BeeperThread } from '../desktop-types'
import { originalParticipantID, originalThreadID } from '../hashing'
import info from '../info'

export interface BridgeV2CurrentUser {
  id: string
  displayName: string
  email?: string
  phoneNumber?: string
}

export interface BridgeV2Participant {
  id: string
  displayName?: string
  email?: string
  phoneNumber?: string
}

export interface BridgeV2Message {
  id: string
  threadID: string
  senderID: string
  text?: string
  timestampMs?: number
  replyToID?: string
}

export interface BridgeV2Thread {
  id: string
  title?: string
  isGroup: boolean
  isSMS: boolean
  participants: BridgeV2Participant[]
  lastMessage?: BridgeV2Message
}

export interface BridgeV2SendMessageRequest {
  text?: string
  filePath?: string
  fileName?: string
  quotedMessageID?: string
}

export interface BridgeV2SendMessageResponse {
  ok: boolean
  messages: BridgeV2Message[]
}

const CLIENT_CONTEXT_DIR = 'bridgev2-client'

function toTimestampMs(value: Date | string | number | undefined): number | undefined {
  if (value == null) return undefined
  if (value instanceof Date) return value.getTime()
  if (typeof value === 'number') return value

  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? undefined : parsed
}

function toParticipant(participant: BeeperThread['participants']['items'][number]): BridgeV2Participant {
  return {
    ...participant,
    id: originalParticipantID(participant.id),
    displayName: participant.displayText,
  }
}

function toMessage(message: BeeperMessage): BridgeV2Message {
  return {
    id: message.id,
    threadID: originalThreadID(message.threadID),
    senderID: originalParticipantID(message.senderID),
    text: message.text,
    timestampMs: toTimestampMs(message.timestamp),
    replyToID: message.linkedMessageID,
  }
}

function toThread(thread: BeeperThread): BridgeV2Thread {
  return {
    id: originalThreadID(thread.id),
    title: thread.title || thread.displayText,
    isGroup: thread.participants.items.length > 1,
    isSMS: Boolean(thread.extra?.isSMS),
    participants: thread.participants.items.map(toParticipant),
    lastMessage: thread.partialLastMessage ? toMessage(thread.partialLastMessage) : undefined,
  }
}

export class BridgeV2iMessageService {
  private readonly api = new AppleiMessage()

  async init(dataDirPath: string): Promise<void> {
    if (process.platform !== 'darwin') {
      throw new Error('platform-imessage BridgeV2 service only runs on macOS')
    }

    const clientDataDirPath = path.join(dataDirPath, CLIENT_CONTEXT_DIR)
    await fs.mkdir(clientDataDirPath, { recursive: true })

    await this.api.init({}, { dataDirPath: clientDataDirPath } as ClientContext)
  }

  async login(): Promise<BridgeV2CurrentUser> {
    const result = await this.api.login()
    if (result.type !== 'success') {
      throw new Error(result.errorMessage || 'Failed to access Messages data')
    }
    return this.getCurrentUser()
  }

  async getCurrentUser(): Promise<BridgeV2CurrentUser> {
    const currentUser = await this.api.getCurrentUser()
    return {
      id: originalParticipantID(currentUser.id),
      displayName: currentUser.displayText,
      email: currentUser.email,
      phoneNumber: currentUser.phoneNumber,
    }
  }

  async getThread(threadID: string): Promise<BridgeV2Thread | null> {
    const thread = await this.api.getThread(threadID as ThreadID) as BeeperThread | undefined
    return thread ? toThread(thread) : null
  }

  async getThreads(pagination?: PaginationArg): Promise<{ items: BridgeV2Thread[], hasMore: boolean, oldestCursor?: string }> {
    const result = await this.api.getThreads(InboxName.NORMAL, pagination)
    return {
      items: result.items.map(thread => toThread(thread as BeeperThread)),
      hasMore: result.hasMore,
      oldestCursor: result.oldestCursor,
    }
  }

  async getMessages(threadID: string, pagination?: PaginationArg): Promise<{ items: BridgeV2Message[], hasMore: boolean }> {
    const result = await this.api.getMessages(threadID as ThreadID, pagination)
    return {
      items: result.items.map(message => toMessage(message as BeeperMessage)),
      hasMore: result.hasMore,
    }
  }

  async sendMessage(threadID: string, request: BridgeV2SendMessageRequest): Promise<BridgeV2SendMessageResponse> {
    const options: MessageSendOptions = request.quotedMessageID ? { quotedMessageID: request.quotedMessageID } : {}
    const result = await this.api.sendMessage(
      threadID as ThreadID,
      {
        text: request.text,
        filePath: request.filePath,
        fileName: request.fileName,
      },
      options,
    )

    if (result === true) {
      return { ok: true, messages: [] }
    }

    return {
      ok: Boolean(result),
      messages: Array.isArray(result) ? result.map(message => toMessage(message as BeeperMessage)) : [],
    }
  }

  async editMessage(threadID: string, messageID: string, text: string): Promise<void> {
    await this.api.editMessage(threadID as ThreadID, messageID, { text })
  }

  async deleteMessage(threadID: string, messageID: string): Promise<void> {
    await this.api.deleteMessage(threadID as ThreadID, messageID)
  }

  async sendReaction(threadID: string, messageID: string, reactionKey: string): Promise<void> {
    await this.api.addReaction(threadID as ThreadID, messageID, reactionKey)
  }

  async removeReaction(threadID: string, messageID: string, reactionKey: string): Promise<void> {
    await this.api.removeReaction(threadID as ThreadID, messageID, reactionKey)
  }

  async sendReadReceipt(threadID: string, messageID?: string): Promise<void> {
    await this.api.sendReadReceipt(threadID as ThreadID, messageID)
  }

  async sendTyping(threadID: string, isTyping: boolean): Promise<void> {
    await this.api.sendActivityIndicator(isTyping ? ActivityType.TYPING : ActivityType.NONE, threadID as ThreadID)
  }

  async deleteThread(threadID: string): Promise<void> {
    await this.api.deleteThread(threadID as ThreadID)
  }

  getBridgeInfo() {
    return {
      bridgeID: info.extra?.bridgeID,
      roomFeatures,
      requiresAccessibilityAccess: info.extra?.requiresAccessibilityAccess,
      requiresContactsAccess: info.extra?.requiresContactsAccess,
    }
  }

  async dispose(): Promise<void> {
    await this.api.dispose()
  }
}
