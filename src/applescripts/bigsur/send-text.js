function (tid, txt, handle) {
  const Messages = Application('Messages')
  const thread = Messages.chats.byId(tid)()
  Messages.send(txt, { to: thread })
}
