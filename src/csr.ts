import childProcess from 'child_process'

export async function csrStatus() {
  const cp = childProcess.spawn('csrutil', ['status'])
  const chunks = []
  cp.stdout.on('data', chunk => {
    chunks.push(chunk)
  })
  return new Promise<string>(resolve => {
    cp.stdout.on('end', () => {
      resolve(Buffer.concat(chunks).toString())
    })
  })
}
