/** Sign final native runtime files before the enclosing Desktop application is signed. */

import { createHash } from 'node:crypto'
import { closeSync, openSync, readSync } from 'node:fs'
import { join } from 'node:path'
import { inventoryDesktopRuntime } from '../src/runtime-tree.ts'
import type { MacOSSigningEnvironment } from './desktop-release-environment.mjs'
import { cachedMacOSSignature, pruneMacOSSignatureCache } from './macos-signature-cache.ts'
import { macOSCachePolicy } from './macos-cache-policy.ts'
import { signMacOSRuntimeCode, signMacOSRuntimeCodeAdHoc, verifyMacOSRuntimeCode } from './verify-macos-signature.mjs'

const MACH_O_MAGICS = new Set(['cafebabe', 'cafebabf', 'cefaedfe', 'cffaedfe', 'feedface', 'feedfacf', 'bebafeca', 'bfbafeca'])

/** One materialized Mach-O file with the inputs every signature strategy shares. */
interface RuntimeMachO {
  readonly file: string
  readonly identifier: string
  readonly entitlements: string | undefined
  readonly thin: boolean
}

function magic(path: string): string {
  const descriptor = openSync(path, 'r')
  try {
    const header = Buffer.alloc(4)
    return readSync(descriptor, header, 0, 4, 0) === 4 ? header.toString('hex') : ''
  } finally { closeSync(descriptor) }
}

/**
 * Apply one signature strategy to every materialized Mach-O file, awaiting all workers on failure.
 * @param root - Self-contained production runtime without symlinks.
 * @param appId - Release application identifier.
 * @param apply - Strategy invoked once per materialized native file.
 * @returns Number of signed native files.
 */
async function signMacOSRuntimeFiles(
  root: string,
  appId: string,
  apply: (entry: RuntimeMachO) => Promise<void>,
): Promise<number> {
  const files = inventoryDesktopRuntime(root).map(file => file.path).filter(path => MACH_O_MAGICS.has(magic(join(root, path))))
  let next = 0
  const workers = Array.from({ length: Math.min(4, files.length) }, async () => {
    for (;;) {
      const path = files[next++]
      if (path === undefined) return
      const identifier = `${appId}.runtime.${createHash('sha256').update(path).digest('hex')}`
      const needsJit = path === 'dependencies/node/bin/node'
        || /^node_modules\/@deepseek-ai\/libreoffice-kit-darwin-(?:arm64|x64)\/bin\/libreoffice-kit$/u.test(path)
      const file = join(root, path)
      await apply({
        file,
        identifier,
        entitlements: needsJit ? join(import.meta.dirname, 'jit-entitlements.plist') : undefined,
        thin: ['cefaedfe', 'cffaedfe', 'feedface', 'feedfacf'].includes(magic(file)),
      })
    }
  })
  const results = await Promise.allSettled(workers)
  const errors = results.filter(result => result.status === 'rejected').map(result => result.reason as unknown)
  if (errors.length > 0) throw new AggregateError(errors, 'desktop runtime: native signing failed')
  return files.length
}

/**
 * Sign and verify every materialized Mach-O file against the release identity.
 * @param root - Self-contained production runtime without symlinks.
 * @param appId - Release application identifier.
 * @param expected - Required signing identity.
 * @param cacheDirectory Optional content-addressed cache; requires the keychain-owned signing probe.
 * @returns Number of signed native files.
 */
export async function signMacOSRuntime(
  root: string, appId: string, expected: MacOSSigningEnvironment, cacheDirectory?: string,
): Promise<number> {
  const policy = cacheDirectory === undefined ? undefined : macOSCachePolicy(process.env.DSH_DESKTOP_MACOS_SIGNING_PROBE ?? '')
  let hits = 0
  let misses = 0
  const signed = await signMacOSRuntimeFiles(root, appId, async ({ file, identifier, entitlements, thin }) => {
    if (cacheDirectory !== undefined && policy !== undefined && thin) {
      if (await cachedMacOSSignature(file, cacheDirectory, policy(identifier, expected, entitlements))) hits++
      else misses++
    } else {
      await signMacOSRuntimeCode(file, identifier, expected, entitlements)
      verifyMacOSRuntimeCode(file, expected)
    }
  })
  if (cacheDirectory !== undefined) {
    pruneMacOSSignatureCache(cacheDirectory)
    console.info(`desktop macOS signing cache: ${hits} hits, ${misses} misses, ${signed - hits - misses} uncached`)
  }
  return signed
}

/**
 * Apply an ad-hoc signature to every materialized Mach-O file for a local, non-distributed build.
 * macOS refuses to execute arm64 code that carries no signature, and a local build owns no release
 * identity, notarization ticket, or update channel.
 * @param root - Self-contained production runtime without symlinks.
 * @param appId - Application identifier used as the signing identifier prefix.
 * @returns Number of signed native files.
 */
export async function adHocSignMacOSRuntime(root: string, appId: string): Promise<number> {
  return signMacOSRuntimeFiles(root, appId, async ({ file, identifier, entitlements }) => {
    await signMacOSRuntimeCodeAdHoc(file, identifier, entitlements)
  })
}
