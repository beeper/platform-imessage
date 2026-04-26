import { installCliGlobals } from './bootstrap'

const IS_DEV = process.env.NODE_ENV !== 'production'
const isLoggingEnabled = process.argv.includes('--verbose')

process.env.IMESSAGE_STRIP_INTERNAL_FIELDS ??= '1'
installCliGlobals(IS_DEV, isLoggingEnabled)

await import('./main')
