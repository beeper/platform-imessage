import { shellExec } from './util'

export function csrStatus() {
  return shellExec('csrutil', 'status')
}
