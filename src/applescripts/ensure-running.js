function () {
  const Messages = Application('Messages')
  if (!Messages.running()) {
    Messages.launch()
    delay(0.2)
  }
}
