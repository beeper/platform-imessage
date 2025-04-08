import Conf from 'conf'

export const normalizeThreadID = (t: string) =>
  t.replaceAll('.', '|')

export default class ThreadReadStore {
  private store: Conf

  constructor(userDataDirPath: string) {
    this.store = new Conf({ cwd: userDataDirPath, configName: 'imessage' })
  }

  markThreadRead(threadID: string, messageID?: string) {
    this.store.set('lastRead.' + normalizeThreadID(threadID), messageID || '')
  }

  isThreadUnread(threadID: string, lastMessageID: string) {
    const lastRead = this.store.store?.lastRead as Record<string, any> | undefined
    return lastRead?.[normalizeThreadID(threadID)] !== lastMessageID
  }
}
