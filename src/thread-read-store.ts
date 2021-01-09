import Conf from 'conf'

const dotRegex = /\./g
export const normalizeThreadID = (t: string) =>
  t.replace(dotRegex, '|')

export default class ThreadReadStore {
  constructor(private readonly userDataDirPath: string) {}

  private store = new Conf({ cwd: this.userDataDirPath, configName: 'imessage' })

  markThreadRead(threadID: string, messageID: string) {
    this.store.set('lastRead.' + normalizeThreadID(threadID), messageID)
  }

  isThreadUnread(threadID: string, lastMessageID: string) {
    return this.store.store?.lastRead?.[normalizeThreadID(threadID)] !== lastMessageID
  }
}
