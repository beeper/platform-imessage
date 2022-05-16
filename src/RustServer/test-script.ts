import { Server } from './lib/index'

function test() {
  const server = new Server(t => {
    console.log(t)
  })

  server.startPoller(0, 577933761537943424)
}

test()
