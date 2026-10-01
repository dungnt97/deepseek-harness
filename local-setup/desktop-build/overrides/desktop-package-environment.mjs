// Local build: the release dotenv file is optional and only the application ID is validated.
import { loadDesktopPackageEnvironment as load } from '../../../apps/desktop/scripts/desktop-package-environment.mjs'
import { resolveDesktopAppId, resolveNpmRegistry } from './desktop-release-environment.mjs'

export * from '../../../apps/desktop/scripts/desktop-package-environment.mjs'

export function loadDesktopPackageEnvironment(platform, environment = process.env, appRoot) {
  try {
    return load(platform, environment, appRoot)
  } catch (error) {
    if (!String(error?.message).includes('cannot read')) throw error
    return { ...environment }
  }
}

export function validateDesktopPackageEnvironment(environment) {
  resolveDesktopAppId(environment)
  resolveNpmRegistry(environment)
}
