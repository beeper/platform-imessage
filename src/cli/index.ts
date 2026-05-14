import { installCliGlobals } from './bootstrap'

const IS_DEV = process.env.NODE_ENV !== 'production'
const isLoggingEnabled = process.argv.includes('--verbose')

installCliGlobals(IS_DEV, isLoggingEnabled)

await import('./main')
