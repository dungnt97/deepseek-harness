// Local build: no Developer ID or notarization account exists, so both resolvers return inert
// placeholders that only the other overrides consume.
export * from '../../../apps/desktop/scripts/desktop-release-environment.mjs'

export function resolveMacOSSigningEnvironment() {
  return { signingIdentity: '-', teamId: 'LOCAL' }
}

export function resolveMacOSNotarizationEnvironment() {
  return {}
}
