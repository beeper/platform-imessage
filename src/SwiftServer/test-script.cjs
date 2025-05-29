// this is a trampoline to `test-script.ts`
//
// swc is in the dev dependencies and is used to support typescript; to run,
// invoke desktop's electron binary
// (../beeper-desktop-new/node_modules/.bin/electron) and pass this script
//
// electron specifically must be used in order to replicate the threading
// environment that is at play when running in production
const { register } = require('@swc-node/register/register')

register()
require('./test-script.ts')
