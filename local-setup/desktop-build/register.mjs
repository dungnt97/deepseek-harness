// Loaded through NODE_OPTIONS=--import by update.sh only. Every import that resolves to one of
// the upstream apps/desktop modules below is answered with this directory's override, which
// swaps Developer ID signing, notarization, and the update channel for a local ad-hoc build,
// so this fork never edits an upstream file. Imports made by an override resolve normally,
// which is how each override reaches the real module it wraps.
// Synchronous registerHooks, not module.register: an async loader thread changes module-not-found
// errors, which breaks pnpm's optional .pnpmfile.mjs probe in every pnpm child process.
import { registerHooks } from 'node:module'
import { fileURLToPath } from 'node:url'

const OVERRIDE_ROOT = new URL('./overrides/', import.meta.url).href
const SCRIPTS = fileURLToPath(new URL('../../apps/desktop/scripts/', import.meta.url))
const OVERRIDES = new Map([
  'desktop-release-environment.mjs',
  'desktop-policy-environment.mjs',
  'desktop-auto-update-environment.mjs',
  'desktop-package-environment.mjs',
  'macos-signing-keychain.mjs',
  'notarize-macos.mjs',
  'macos-runtime.ts',
  'electron-builder-config.mjs',
].map(name => [SCRIPTS + name, new URL(name.replace(/\.ts$/u, '.mjs'), OVERRIDE_ROOT).href]))

registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context)
    if (!resolved.url.startsWith('file:') || context.parentURL?.startsWith(OVERRIDE_ROOT)) return resolved
    const override = OVERRIDES.get(fileURLToPath(resolved.url))
    return override === undefined ? resolved : { url: override, format: 'module', shortCircuit: true }
  },
})
