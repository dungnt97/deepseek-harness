// Local build: no signing certificate to import, so the action runs with the plain environment.
export * from '../../../apps/desktop/scripts/macos-signing-keychain.mjs'

export async function withMacOSSigningKeychain(environment, action) {
  return action(environment)
}
