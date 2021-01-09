function (tid, txt, handle) {
  const Messages = Application('Messages')
  let thread
  try {
    thread = Messages.textChats.byId(tid)()
  } catch (e) { }
  if (!thread) {
    try {
      thread = Messages.buddies.whose({ handle })[0]
    } catch (e) { }
  }
  Messages.send(txt, { to: thread })
}
