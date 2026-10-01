// Local build: ad-hoc sign every materialized Mach-O file of the runtime instead of using a
// Developer ID. Mirrors upstream signMacOSRuntime's file selection and entitlement choice.
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { closeSync, openSync, readSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { inventoryDesktopRuntime } from '../../../apps/desktop/src/runtime-tree.ts'

export * from '../../../apps/desktop/scripts/macos-runtime.ts'

const SCRIPTS = fileURLToPath(new URL('../../../apps/desktop/scripts/', import.meta.url))
const MACH_O_MAGICS = new Set(['cafebabe', 'cafebabf', 'cefaedfe', 'cffaedfe', 'feedface', 'feedfacf', 'bebafeca', 'bfbafeca'])
const run = promisify(execFile)

function magic(path) {
  const descriptor = openSync(path, 'r')
  try {
    const header = Buffer.alloc(4)
    return readSync(descriptor, header, 0, 4, 0) === 4 ? header.toString('hex') : ''
  } finally { closeSync(descriptor) }
}

export async function signMacOSRuntime(root, appId, _expected, arch) {
  const files = inventoryDesktopRuntime(root).map(file => file.path).filter(path => MACH_O_MAGICS.has(magic(join(root, path))))
  let next = 0
  const workers = Array.from({ length: Math.min(4, files.length) }, async () => {
    for (;;) {
      const path = files[next++]
      if (path === undefined) return
      const identifier = `${appId}.runtime.${createHash('sha256').update(path).digest('hex')}`
      const isNode = path === 'dependencies/node/bin/node'
      const needsJit = isNode
        || /^node_modules\/@deepseek-ai\/libreoffice-kit-darwin-(?:arm64|x64)\/bin\/libreoffice-kit$/u.test(path)
      const entitlements = isNode && arch === 'x64' ? 'node-x64-entitlements.plist' : 'jit-entitlements.plist'
      await run('/usr/bin/codesign', [
        '--force', '--sign', '-', '--identifier', identifier,
        ...(needsJit ? ['--entitlements', join(SCRIPTS, entitlements)] : []),
        join(root, path),
      ])
    }
  })
  const results = await Promise.allSettled(workers)
  const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length > 0) throw new AggregateError(errors, 'desktop runtime: ad-hoc native signing failed')
  return files.length
}
