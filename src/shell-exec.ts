import childProcess from 'node:child_process'

export async function shellExec(command: string, ...args: readonly string[]): Promise<string> {
  const cp = childProcess.spawn(command, args)

  const chunks: Buffer[] = []
  const errors: Buffer[] = []
  cp.stdout.on('data', chunk => { chunks.push(Buffer.from(chunk)) })
  cp.stderr.on('data', chunk => { errors.push(Buffer.from(chunk)) })

  return new Promise<string>((resolve, reject) => {
    cp.on('exit', code => {
      if (code) {
        reject(new Error(`${command} exited with status code ${code}: ${Buffer.concat(errors).toString('utf8')}`))
      } else {
        resolve(Buffer.concat(chunks).toString('utf8'))
      }
    })
  })
}
