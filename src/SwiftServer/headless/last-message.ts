import type { ThreadID } from '@textshq/platform-sdk'

import { CHAT_DB_PATH } from '../../constants'
import { shellExec } from '../../shell-exec'

const GET_LAST_MESSAGE_SQL = `SELECT
m.guid AS messageID
FROM message AS m
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE t.guid = '%THREAD_ID%'
ORDER BY m.date DESC
LIMIT 1`

const escapeSqlString = (value: string) => value.replaceAll("'", "''")

export async function getLastMessageID(threadID: ThreadID): Promise<string> {
  const sql = GET_LAST_MESSAGE_SQL.replace('%THREAD_ID%', escapeSqlString(threadID))
  const messageID = (await shellExec('sqlite3', CHAT_DB_PATH, sql)).trim()
  if (!messageID) throw new Error(`No messages found for thread ${threadID}`)
  return messageID
}
