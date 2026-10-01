// Local build: no update channel, so electron-builder writes no updater configuration.
export * from '../../../apps/desktop/scripts/desktop-auto-update-environment.mjs'

export function resolveDesktopAutoUpdateConfig() {
  return undefined
}
