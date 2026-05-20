import './fix-env'

import { execFileSync } from 'child_process'
import fs from 'fs'
import path from 'path'

const nativeAddonPaths = ['darwin-x64', 'darwin-arm64']
  .map(archDir => ({
    archDir,
    binaryPath: path.join(__dirname, '../../binaries', archDir, 'IMessage.node'),
  }))
  .filter(({ binaryPath }) => fs.existsSync(binaryPath))

const describeOnDarwin = process.env.IMESSAGE_CHECK_NATIVE_BINARY === '1' && process.platform === 'darwin' && nativeAddonPaths.length > 0
  ? describe
  : describe.skip

describeOnDarwin('native addon compatibility', () => {
  it.each(nativeAddonPaths)('keeps $archDir loadable on older supported macOS releases', ({ binaryPath }) => {
    const undefinedSymbols = execFileSync('/usr/bin/nm', ['-u', binaryPath], { encoding: 'utf8' })
    expect(undefinedSymbols).not.toContain('_$s10Foundation10POSIXErrorV')

    const loadCommands = execFileSync('/usr/bin/otool', ['-l', binaryPath], { encoding: 'utf8' })
    expect(loadCommands).toMatch(/^\s+minos 11\.0$/m)
  })
})
