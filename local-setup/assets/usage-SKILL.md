---
name: usage
description: Show the OpenCode Go subscription quota — the rolling, weekly, and monthly allowance with how much is left and when each window resets. Use when asked how much of the OpenCode Go plan is left, whether a limit is near, how many hours until reset, or when a request fails with a quota, rate-limit, or balance error.
user-invocable: true
whenToUse: Invoke when the user asks about OpenCode Go usage, remaining quota, limits, reset times, or a quota/balance failure.
---

# OpenCode Go subscription quota

Run the report and show its output verbatim:

```sh
~/.dsh/bin/opencode-usage.py
```

The script calls OpenCode's own quota endpoint
(`https://opencode.ai/zen/go/v1/usage`) with the key the Harness already uses
(`OPENCODE_API_KEY`, then `OPENCODE_GO_API_KEY`, then the credential store), and
never prints the key. `--json` emits the raw response.

## Reading the result

Three windows, each an independent allowance — exhausting one does not consume the
others:

| Window | Covers |
|---|---|
| `rolling` | The short burst window; resets a few hours out. |
| `weekly` | The week's allowance. |
| `monthly` | The plan's monthly allowance. |

`percent` is **used**, so a high number means little is left. `status` other than
`ok` marks a restricted window; surface it rather than summarizing it away.

## When a window is nearly exhausted

- Report which window and how long until it resets instead of only the percentage.
- A failure mentioning balance or credits means the window is spent, not that the key
  is wrong — check `status` before suggesting any credential change.
- Do not switch keys or endpoints on your own.

## Not the same thing

`opencode stats` reports tokens and cost the **opencode CLI** recorded in its own
local database. That is consumption history for that tool only; it says nothing
about the Go plan's remaining allowance. Use it only when the question is about the
CLI's own past usage.
