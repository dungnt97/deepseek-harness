# dsh-opencode-go-quota

A DeepSeek Harness plugin that answers one question: **how much of the OpenCode Go plan
is left?** It registers the chat command `/opencode-go` and reports the rolling, weekly,
and monthly allowance with reset times.

## Why this exists

OpenCode serves the subscription allowance next to the model API:

```
GET https://opencode.ai/zen/go/v1/usage
{"usage":{"rolling":{"status":"ok","percent":10,"resetsAt":"…"},
          "weekly":{"status":"ok","percent":27,"resetsAt":"…"},
          "monthly":{"status":"ok","percent":13,"resetsAt":"…"}}}
```

`opencode stats` is a different measurement: it reads the opencode CLI's own local
database and reports tokens and cost that tool recorded, which says nothing about the
plan's remaining allowance.

The published quota plugins also render a sidebar widget, but they declare
`inject: ['webServer', …]`, and the Desktop application disables `webserver` — a plugin
whose injected service is absent never applies. This plugin requires only `commands` and
`credentials`, so it mounts in every profile, and gives up the widget a Web-server route
would have served.

## Install

The Desktop plugin manager accepts npm registry specs only, so installing there means
publishing this package and pasting `<name>@<version>` into Desktop → Plugins (`⌘,`).
Any other profile can take it straight from a tarball, because a package declaring
`dsh.bundle.patch` joins `dsh.profile.bundles` on install:

```sh
npm pack
pnpm dsh plugin --profile web add "file:$PWD/dsh-opencode-go-quota-1.0.0.tgz"
pnpm dsh --profile web
```

## Configuration

`apply(ctx, config)` reads two optional fields, so a deployment can override them in its
profile patch without editing this package:

| Field | Default | Purpose |
|---|---|---|
| `apiKeyEnv` | `OPENCODE_API_KEY` | Credential reference resolved through the Harness credentials service; `OPENCODE_GO_API_KEY` is tried next. |
| `baseUrl` | `https://opencode.ai/zen/go` | Gateway root; the quota endpoint is `<baseUrl>/v1/usage`. |

The key is never logged, printed, or written anywhere.

## Behaviour

- A window whose `status` is not `ok` is marked rather than summarized away.
- Failures come back as the command's error text: `HTTP 401` means the credential is not
  a Go key, `HTTP 404` means the endpoint moved.
- No caching: the command reports the gateway's current numbers.
