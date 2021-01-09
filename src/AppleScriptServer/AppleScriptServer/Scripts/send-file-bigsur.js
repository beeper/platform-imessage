function (tid, fp, handle) {
  const Messages = Application('Messages')
  const thread = Messages.chats.byId(tid)()
  Messages.send(Path(fp), { to: thread })
}
