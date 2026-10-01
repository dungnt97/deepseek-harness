// Local build: never distributed, so it embeds no mandatory-update policy.
export * from '../../../apps/desktop/scripts/desktop-policy-environment.mjs'

export function resolveDesktopPolicyEnvironment() {
  return undefined
}
