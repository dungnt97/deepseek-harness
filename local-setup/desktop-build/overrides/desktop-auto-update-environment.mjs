// Local build: the update channel is the machine-local feed update.sh publishes to (served by the
// ai.dsh.update-feed LaunchAgent). Upstream's afterPack writes it into app-update.yml, which is
// what enables the application's own Check for Updates and download-progress dialogs. Without
// DSH_LOCAL_UPDATE_FEED_URL the build carries no update channel.
import { resolveDesktopAutoUpdateTarget } from '../../../apps/desktop/scripts/desktop-auto-update-environment.mjs'

export * from '../../../apps/desktop/scripts/desktop-auto-update-environment.mjs'

export function resolveDesktopAutoUpdateConfig(env, platform, arch) {
  const publicUrl = env.DSH_LOCAL_UPDATE_FEED_URL
  if (publicUrl === undefined || publicUrl === '') return undefined
  const url = new URL(publicUrl)
  if (url.hostname !== '127.0.0.1' || !url.pathname.endsWith('/')) {
    throw new Error('local update feed: DSH_LOCAL_UPDATE_FEED_URL must be http://127.0.0.1:<port>/…/')
  }
  return {
    environment: 'test',
    target: resolveDesktopAutoUpdateTarget(platform, arch),
    origin: url.origin,
    keyPrefix: '',
    binaryKeyPrefix: '',
    publicUrl: url.href,
  }
}
