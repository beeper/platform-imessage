function (tid, fp, handle) {
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
  Messages.send(Path(fp), { to: thread })
}
