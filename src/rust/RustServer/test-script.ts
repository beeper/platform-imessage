import { Server } from './lib/index'

function test() {
  const server = new Server(t => {
    console.log(t)
  })

  server.startPoller(0n, 577933761537943424n)
}

test()
