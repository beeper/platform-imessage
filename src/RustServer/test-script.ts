const childProcess = require('child_process')
const cp = childProcess.spawn('./target/release/rust_server')

cp.stdout.on('data', (chunk: Buffer) => {
  const data = chunk.toString()
  console.log(data)
})
cp.stdin.on('error', (err) => {
	console.log(`cp.stdin.error: ${err}`)
})
cp.on('error', (error) => {
  console.log(`cp.error: ${error}`)
})

setTimeout(() => {
  const json = {
    method: 'set',
    args: [6643, 624394928941777024]
  }
  console.log('Writing', { json })
  cp.stdin.write(JSON.stringify(json) + "\n")
}, 1000)

setTimeout(() => {
  const json = {
    method: 'stop',
  }
  console.log('Writing', { json })
  cp.stdin.write(JSON.stringify(json) + "\n")
}, 4500)
