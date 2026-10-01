// Local build: electron-builder skips Developer ID signing, hardened runtime, notarization, and
// the release signature check; update.sh ad-hoc signs the finished bundle.
import { createElectronBuilderConfig as create } from '../../../apps/desktop/scripts/electron-builder-config.mjs'

export * from '../../../apps/desktop/scripts/electron-builder-config.mjs'

export function createElectronBuilderConfig(...args) {
  const config = create(...args)
  const afterSign = config.afterSign
  return {
    ...config,
    mac: { ...config.mac, identity: null, forceCodeSigning: false, hardenedRuntime: false, notarize: false },
    dmg: { ...config.dmg, sign: false },
    afterSign: context => context.electronPlatformName === 'darwin' ? undefined : afterSign?.(context),
    artifactBuildCompleted: undefined,
  }
}
