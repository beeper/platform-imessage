import { stdin as input, stdout as output } from 'process'

import { BridgeV2iMessageService } from './service'

type CLICommand =
  | 'login'
  | 'get-current-user'
  | 'get-thread'
  | 'get-threads'
  | 'get-messages'
  | 'send-message'
  | 'edit-message'
  | 'delete-message'
  | 'send-reaction'
  | 'remove-reaction'
  | 'send-read-receipt'
  | 'send-typing'
  | 'delete-thread'
  | 'get-bridge-info'

interface CLIRequest {
  command: CLICommand
  dataDirPath: string
  payload?: Record<string, unknown>
}

function readStdin(): Promise<string> {
  return new Promise((resolve, reject) => {
    let raw = ''
    input.setEncoding('utf8')
    input.on('data', chunk => { raw += chunk })
    input.on('end', () => resolve(raw))
    input.on('error', reject)
  })
}

async function readRequest(): Promise<CLIRequest> {
  const rawRequest = process.argv[2] || await readStdin()
  if (!rawRequest) {
    throw new Error('missing BridgeV2 CLI request payload')
  }
  return JSON.parse(rawRequest) as CLIRequest
}

async function main() {
  const request = await readRequest()
  const service = new BridgeV2iMessageService()

  try {
    await service.init(request.dataDirPath)

    switch (request.command) {
      case 'login':
        output.write(JSON.stringify(await service.login()))
        break
      case 'get-current-user':
        output.write(JSON.stringify(await service.getCurrentUser()))
        break
      case 'get-thread':
        output.write(JSON.stringify(await service.getThread(String(request.payload?.threadID || ''))))
        break
      case 'get-threads':
        output.write(JSON.stringify(await service.getThreads(request.payload as never)))
        break
      case 'get-messages':
        output.write(JSON.stringify(await service.getMessages(
          String(request.payload?.threadID || ''),
          request.payload?.pagination as never,
        )))
        break
      case 'send-message':
        output.write(JSON.stringify(await service.sendMessage(
          String(request.payload?.threadID || ''),
          request.payload as never,
        )))
        break
      case 'edit-message':
        await service.editMessage(
          String(request.payload?.threadID || ''),
          String(request.payload?.messageID || ''),
          String(request.payload?.text || ''),
        )
        output.write(JSON.stringify({ ok: true }))
        break
      case 'delete-message':
        await service.deleteMessage(
          String(request.payload?.threadID || ''),
          String(request.payload?.messageID || ''),
        )
        output.write(JSON.stringify({ ok: true }))
        break
      case 'send-reaction':
        await service.sendReaction(
          String(request.payload?.threadID || ''),
          String(request.payload?.messageID || ''),
          String(request.payload?.reactionKey || ''),
        )
        output.write(JSON.stringify({ ok: true }))
        break
      case 'remove-reaction':
        await service.removeReaction(
          String(request.payload?.threadID || ''),
          String(request.payload?.messageID || ''),
          String(request.payload?.reactionKey || ''),
        )
        output.write(JSON.stringify({ ok: true }))
        break
      case 'send-read-receipt':
        await service.sendReadReceipt(
          String(request.payload?.threadID || ''),
          request.payload?.messageID ? String(request.payload.messageID) : undefined,
        )
        output.write(JSON.stringify({ ok: true }))
        break
      case 'send-typing':
        await service.sendTyping(
          String(request.payload?.threadID || ''),
          Boolean(request.payload?.isTyping),
        )
        output.write(JSON.stringify({ ok: true }))
        break
      case 'delete-thread':
        await service.deleteThread(String(request.payload?.threadID || ''))
        output.write(JSON.stringify({ ok: true }))
        break
      case 'get-bridge-info':
        output.write(JSON.stringify(service.getBridgeInfo()))
        break
      default:
        throw new Error(`unsupported BridgeV2 CLI command: ${String(request.command)}`)
    }
  } finally {
    await service.dispose().catch(() => {})
  }
}

main().catch(error => {
  console.error(error)
  process.exitCode = 1
})
