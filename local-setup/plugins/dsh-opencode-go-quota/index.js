/**
 * OpenCode Go quota as a chat command, for harness profiles that provide no Web server.
 *
 * The published quota plugins declare `inject: ['webServer', …]`, so they never apply
 * in the Desktop application: `apps/desktop-host/config/desktop.cordis.patch.yml`
 * disables `webserver`, and a plugin whose injected service is absent does not mount.
 * This one needs only `commands` and `credentials`, so it mounts everywhere, at the
 * cost of the sidebar widget a Web-server route could serve.
 *
 * It queries the official allowance endpoint; `opencode stats` is a different thing
 * (that CLI's own local token and cost history).
 *
 * @module dsh-opencode-go-quota
 */

/** Stable cordis plugin name. */
export const name = 'opencode-go-quota'

/** Host services this plugin requires; every harness profile provides these. */
export const inject = ['commands', 'credentials']

/** Gateway root; the quota endpoint is `<baseUrl>/v1/usage`. */
const DEFAULT_BASE_URL = 'https://opencode.ai/zen/go'

/** Credential reference the Harness already uses for this plan. */
const DEFAULT_KEY_REF = 'OPENCODE_API_KEY'

/** Credential references tried in order when the configured one is absent. */
const FALLBACK_KEY_REFS = ['OPENCODE_GO_API_KEY']

/** The windows the gateway reports, in the order worth reading them. */
const WINDOWS = [
  ['rolling', 'rolling (short burst)'],
  ['weekly', 'weekly'],
  ['monthly', 'monthly'],
]

/**
 * Resolve the first credential reference that holds a key.
 * @param ctx - Cordis context carrying the credentials service.
 * @param refs - Credential references to try, in order.
 * @returns The reference and value in use.
 * @throws When no reference resolves to a non-empty value.
 */
async function resolveKey(ctx, refs) {
  for (const ref of refs) {
    const hit = await ctx.credentials.resolve(ref)
    if (hit !== undefined && hit !== null && typeof hit.value === 'string' && hit.value !== '') {
      return { ref, value: hit.value }
    }
  }
  throw new Error(`no API key: set credential ${refs.join(' or ')}`)
}

/**
 * Fetch the plan allowance from the gateway.
 * @param baseUrl - Gateway root without a trailing slash.
 * @param key - Bearer token.
 * @returns The decoded response body.
 * @throws When the gateway rejects the request or the transport fails.
 */
async function fetchUsage(baseUrl, key) {
  const response = await fetch(`${baseUrl}/v1/usage`, {
    headers: { authorization: `Bearer ${key}`, accept: 'application/json' },
    signal: AbortSignal.timeout(15_000),
  })
  if (!response.ok) {
    const body = await response.text().catch(() => '')
    throw new Error(`HTTP ${response.status}${body === '' ? '' : `: ${body.slice(0, 200)}`}`)
  }
  return await response.json()
}

/**
 * Render one window as a bar plus the local time it resets.
 * @param label - Display label for the window.
 * @param window - One `usage` entry from the response.
 * @param now - Current instant, for the countdown.
 * @returns One output line.
 */
function renderWindow(label, window, now) {
  const percent = typeof window.percent === 'number' ? window.percent : 0
  const filled = Math.max(0, Math.min(20, Math.round(percent / 5)))
  const bar = `[${'#'.repeat(filled)}${'-'.repeat(20 - filled)}]`
  const status = window.status === undefined || window.status === 'ok' ? '' : `  [${window.status}]`
  const resets = typeof window.resetsAt === 'string' ? `  resets ${resetText(window.resetsAt, now)}` : ''
  return `  ${label.padEnd(22)} ${percent.toFixed(1).padStart(5)}% used  ${bar}  ${(100 - percent).toFixed(1).padStart(5)}% left${resets}${status}`
}

/**
 * Describe a reset instant in local time with a compact countdown.
 * @param resetsAt - ISO instant from the response.
 * @param now - Current instant.
 * @returns Local timestamp and countdown, or the raw value when unparsable.
 */
function resetText(resetsAt, now) {
  const when = new Date(resetsAt)
  if (Number.isNaN(when.getTime())) return resetsAt
  const minutes = Math.round((when.getTime() - now.getTime()) / 60_000)
  const countdown = minutes < 0
    ? 'due'
    : minutes < 60
      ? `${minutes}m`
      : minutes < 2_880
        ? `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m`
        : `${Math.floor(minutes / 1_440)}d ${String(Math.floor(minutes / 60) % 24).padStart(2, '0')}h`
  const stamp = new Intl.DateTimeFormat(undefined, { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }).format(when)
  return `${stamp} (in ${countdown})`
}

/**
 * Render the whole response.
 * @param payload - Decoded gateway response.
 * @param now - Current instant.
 * @returns The command's report text.
 */
function render(payload, now) {
  const usage = payload?.usage
  if (usage === null || typeof usage !== 'object') {
    return `OpenCode Go: unexpected response ${JSON.stringify(payload).slice(0, 200)}`
  }
  const lines = ['OpenCode Go — subscription quota']
  for (const [key, label] of WINDOWS) {
    const window = usage[key]
    if (window !== null && typeof window === 'object') lines.push(renderWindow(label, window, now))
  }
  return lines.join('\n')
}

/**
 * Register the `/opencode-go` command.
 * @param ctx - Cordis context.
 * @param config - Loader entry config; `baseUrl` and `apiKeyEnv` override the defaults.
 */
export function apply(ctx, config = {}) {
  const baseUrl = String(config.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, '')
  const refs = [String(config.apiKeyEnv ?? DEFAULT_KEY_REF), ...FALLBACK_KEY_REFS]

  ctx.commands.register({
    name: 'opencode-go',
    description: 'show the OpenCode Go plan quota (rolling, weekly, monthly)',
    handler: async () => {
      try {
        const key = await resolveKey(ctx, refs)
        const payload = await fetchUsage(baseUrl, key.value)
        return { kind: 'success', text: render(payload, new Date()) }
      } catch (error) {
        return { kind: 'error', text: `OpenCode Go: ${error instanceof Error ? error.message : String(error)}` }
      }
    },
  })
}
