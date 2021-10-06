import { shellExec } from './util'

export async function csrStatus() {
  return shellExec('csrutil', 'status')
}
