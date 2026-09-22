# DSH machine setup

Everything this machine needs so a DeepSeek Harness session can **read images**,
**search the web** on the OpenCode Go plan, **reach Homebrew and the AgentKit CLI from
an app opened in Finder**, **see AgentKit's skills** in its own catalog, **report the Go
plan's remaining quota**, and **rebuild the application when upstream moves**. One
command, re-runnable:

```bash
bash ~/deepseek-harness/local-setup/install.sh
```

Run it after a Harness update, after a fresh clone, or whenever `read_image`,
`web_search`, or `ak` starts refusing. It is idempotent and backs up `settings.yaml`
first.

## Setting up another Mac

The branch, the patches, and these scripts travel in Git. The credentials, the settings,
and the built application do not. On a second Apple Silicon Mac:

1. **Prerequisites:** macOS on Apple Silicon, Xcode Command Line Tools
   (`xcode-select --install`), Node.js `^22.19 || >=24`, and Git access to
   `git@github.com:dungnt97/deepseek-harness.git`. Python 3 comes with the tools.
2. **Clone outside a TCC-protected directory** — `~/deepseek-harness`, never
   `~/Documents` ([why](#why-the-repository-lives-in-deepseek-harness)) — and check out
   the branch the build reads:

   ```bash
   git clone git@github.com:dungnt97/deepseek-harness.git ~/deepseek-harness
   cd ~/deepseek-harness && git checkout desktop-local
   ```
3. **Machine-level pieces:** `bash local-setup/install.sh`. It installs the relay,
   LaunchAgents, settings, and skills, adds the fetch-only `upstream` remote a fresh clone
   lacks, and ends with `verify.sh`.
4. **Build and install the application:** `bash local-setup/update.sh --force`. `--force`
   is required because the fresh clone is already level with upstream. The first build
   runs several minutes and downloads Electron and the bundled runtime. No Apple Developer
   identity is needed: the local build is ad-hoc signed.
5. **Credentials stay per machine.** `DEEPSEEK_API_KEY` and the OpenCode Go key live in
   `~/.dsh/settings.yaml`, never in the repository; the sections above name the key each
   capability needs.

---

## Why any of this is needed

Both gaps are **declaration/config gaps in the Harness, not broken models or keys.**
Each was measured before it was fixed; the measurements are in the comments beside
the code that depends on them.

### 1. Images — the model was never declared as image-capable

`read_image` refuses with *"model deepseek-v4.1-flash does not declare image input"*.
The gate (`dsh-tool-fs/lib/index.js` → `assertImageCapableRoute`) requires
`resolveModelInfo(...).inputModalities` to contain `"image"`. For the pi-ai adapter:

```
input = declaredInput(entry.input) ?? base?.input ?? [...request.defaultInput]
DEFAULT_INPUT = ["text"]
```

`deepseek-v4.1-flash` is in **no bundled catalogue**, so `base` is undefined and it
falls to `["text"]` — the harness's deliberate under-claim, because *"nothing can
interrogate a gateway for its modalities"*. That premise holds: `GET
https://opencode.ai/zen/go/v1/models` returns only `id/object/created/owned_by`.

**But the model does see images.** Three solid 8×8 PNGs (red/blue/green) posted to
`/zen/go/v1/chat/completions` answered `Red` / `Blue` / `Green` correctly, with a
text-only control returning 200 on the same route.

**Fix:** one line — `input: [text, image]` on the entry. No restart, no model switch.

### 2. Web search — the plugin cannot send a header Go requires

The bundled search provider (`dsh-web-search-deepseek`) calls an Anthropic-compatible
Messages endpoint using `DEEPSEEK_API_KEY`, which on this machine is **invalid**
(`…10Tq`; a direct call answers `401 Authentication Fails`). It is a *different* key
from the working OpenCode one (`…A8Ej`).

OpenCode Go would serve it — but `/zen/go/v1/messages` answers
`400 MissingSessionID` **on every request, for every model, listed or not**, unless
`x-opencode-session` is present. The plugin cannot send it: its config schema is
`{apiKey, apiKeyEnv, baseURL, model, apiVersion, maxTokens, maxUses}` — **no `headers`
field** — and its fetch header set is hard-coded.

This is a **known upstream gap**. OpenCode's Go documentation lists DeepSeek Harness
under *"Known Problematic Clients"*:

> "Session information arrives on some model paths, but is missing on others. We
> recognize its native header; the remaining work is to send it across all adapters."
> — [discussion #5495](https://github.com/deepseek-ai/deepseek-harness/discussions/5495)

**Fix:** `go-search-proxy.py`, a loopback relay that adds exactly that one header, and
`web-search-deepseek.baseURL` pointing at it.

### 3. Shell PATH — a Finder-launched app gets launchd's four directories

`launchctl getenv PATH` was empty and a session's shell ran with
`/usr/bin:/bin:/usr/sbin:/sbin`: **neither Homebrew nor `~/.local/bin`**, so `node`,
`git`, and `ak` were all `MISSING`. This is not a Harness bug — launchd gives
every app opened from Finder that minimal PATH, and the Harness shell tool inherits
the application's environment (the session env carries
`__CFBundleIdentifier=com.deepseek.harness.desktop`).

**Fix:** a second LaunchAgent, `ai.dsh.gui-path`, runs `set-gui-path.sh` at login. The
script takes the login shell's own PATH, prepends `~/.local/bin`, and publishes it with
`launchctl setenv PATH`. An app launched afterwards inherits it; an app already running
does not, so **quit and reopen DeepSeek Harness.app** after the first install.

The same step installs **pnpm** when the machine has none, pinned to the version the
repo's `packageManager` field declares (`pnpm@11.7.0`), so a session can run
`pnpm run <script>` without a second manual install. An existing pnpm is never replaced;
a version that differs from the pin is reported instead.

### 4. AgentKit skills — AgentKit has a `dsh` adapter, but no kit targets it

`ak` 2.15.0 registers `dsh` among its adapters (`ak setup --adapter … dsh …`), and its
binary contains a real emitter (`internal/adapters/dsh`). Enabling the adapter works:

```
adapters:
    enabled: claude-code,omp,pi,dsh
```

Installing content for it does not. Both channels answer the same way:

```
$ ak kit install engineer --target dsh --global
Error: init: lifecycle preflight: remote install: unsupported runtime target "dsh"
```

The registry serves one artifact per runtime (`~/.agentkit/cache/kits/engineer/<target>/`),
and only `omp` and `claude-code` exist for `engineer` — no kit declares `dsh` yet.

Two further gaps sit behind that one:

- **88 skills already exist** at `~/.claude/skills` (ClaudeKit content, unmarked by
  AgentKit), and `dsh-skill-filesystem` scans none of them.
- Of those 88, **only 2 have a name the Harness accepts.** ClaudeKit names 85
  `ck:<skill>` and one `ckm:<skill>`; the Harness requires
  `/^[a-z0-9]+(?:-[a-z0-9]+)*$/` and **drops the whole skill** on a mismatch
  (`skill file … ignored: invalid skill name "ck:brainstorm"`). It also discovers only
  top-level `<name>/SKILL.md`, so the four bundles under `document-skills/` are invisible
  even with a valid name.

**Fix:** `ensure_skills.py` mirrors the skills into `~/.dsh/skills` — the `user-dsh` root
the Harness scans — rewriting the frontmatter `name:` to a valid slug and flattening the
nested bundles. It is a generated mirror, not a second source of truth: re-run it after
AgentKit changes its skills, and it refreshes what it owns and prunes the rest. Bundles
it did not create are left alone, and its manifest lives at
`~/.dsh/skills/.agentkit-mirror`. Measured after the first run: **88 skills in the
session catalog**, up from 2.

Once a kit ships a `dsh` variant, `ak kit install <kit> --target dsh --global` replaces
this script — the adapter is already enabled, so nothing else needs to change.

### 5. OpenCode Go quota — the allowance has its own endpoint

OpenCode serves the subscription allowance next to the model API, and nothing else
reports it:

```
GET https://opencode.ai/zen/go/v1/usage
{"usage":{"rolling":{"status":"ok","percent":10,"resetsAt":"…"},
          "weekly":{"status":"ok","percent":27,"resetsAt":"…"},
          "monthly":{"status":"ok","percent":13,"resetsAt":"…"}}}
```

`opencode stats` is **not** this. It reads the opencode CLI's own local database and
reports tokens and cost that tool recorded — consumption history, not what is left on
the plan.

**Fix:** `opencode-usage.py` calls the endpoint with the key the Harness already uses
(`OPENCODE_API_KEY`, then `OPENCODE_GO_API_KEY`, then the credential store) and renders
the three windows with a bar and a local reset time. It installs as a `/usage` skill, so
a session can show it without any shell command from you.

Two published plugins do the same thing with a sidebar widget
([`dsh-opencode-go-usage`](https://www.npmjs.com/package/dsh-opencode-go-usage),
[`@dong-victor/dsh-opencodego-usage`](https://www.npmjs.com/package/@dong-victor/dsh-opencodego-usage)),
and their code is clean — no install scripts, the official endpoint, the key resolved
through the credentials service. **They do not work in the Desktop application:** both
declare `inject: ['webServer', …]`, and Desktop deliberately disables `webserver`
(`apps/desktop-host/config/desktop.cordis.patch.yml`, and the Desktop README: *"Desktop
does not provide a `webServer`"*). A plugin whose injected service is absent never
applies, so installing one there buys a sidebar widget that cannot render. Use them only
under a listening-profile run (`dsh --profile web`).

`plugins/dsh-opencode-go-quota/` is a local plugin built for exactly that gap: it mounts
with `inject: ['commands', 'credentials']` alone, so it needs no Web server and works
wherever the Harness runs. It registers the chat command `/opencode-go` and nothing else
— no sidebar widget, because only a Web-server route could serve one.

**It cannot be installed into the Desktop application.** The Desktop plugin manager
accepts npm registry specs only — `packageNameFromSpec` rejects `file:`, `://`, paths,
whitespace, and a leading `-` (`apps/desktop/src/project-manager.ts`) — and the launcher
refuses the profile outright: `dsh plugin --profile desktop …` answers *"profile
"desktop" is managed exclusively by the Electron application"* (`apps/cli/src/args.ts`).
So a custom Desktop plugin needs a registry: publish it, then paste
`dsh-opencode-go-quota@1.0.0` into Desktop → Plugins (`⌘,`). Without publishing, install
it into a profile you can drive yourself:

```bash
cd ~/deepseek-harness/local-setup/plugins/dsh-opencode-go-quota && npm pack
pnpm dsh plugin --profile web add "file:$HOME/dsh-opencode-go-quota-1.0.0.tgz"
pnpm dsh --profile web            # /opencode-go is then available
```

A package declaring `dsh.bundle.patch` joins `dsh.profile.bundles` automatically, so the
install needs no manual patch edit. Remove it with `… plugin --profile web remove
dsh-opencode-go-quota`. Until it reaches a profile, `/usage` above is the
Desktop answer.

### 6. Updating the application — it is built from source, so upstream needs a rebuild

The installed application comes from this working tree, not from the signed release
feed, so a new upstream commit means a new build. The repository is a **fork**: the
local desktop patches live on branch `desktop-local` pushed to
`dungnt97/deepseek-harness` (`origin`), and `deepseek-ai/deepseek-harness` is
`upstream`, configured **fetch-only** — `git remote -v` shows `DISABLED_NO_PUSH`, so a
stray push fails instead of reaching someone else's repository.

**Fix:** `check-update.sh`, on the six-hourly LaunchAgent `ai.dsh.repo-update`, fetches
upstream and — when HEAD is behind — shows **one alert with a real Update button**
(`osascript display dialog`, no extra tooling). Confirming hands the work to
`update.sh`, which merges upstream `master` into `desktop-local`, installs dependencies, rebuilds and
packages, ad-hoc signs, quits the application, replaces `/Applications`, and relaunches.

What keeps it safe:

| Property | How |
|---|---|
| One prompt per upstream state | The asked-about SHA is recorded in `~/.dsh/update-notified`; "Later" is not re-asked until upstream moves, and an update that fails clears the record so the same state is offered again. |
| Never a half-installed app | The new bundle is built **and signature-verified before** the installed one is touched. |
| A conflict cannot break anything | A failed merge is aborted; the installed application is left alone and a notification says it needs attention. |
| Preview without side effects | `bash update.sh --dry-run` reports what it would do and stops. |
| Install a bundle that already exists | `bash update.sh --install-only` signs and installs the existing bundle and restarts the app — about a second, because APFS clones the 550 MB copy. Use it after a build, or to finish an update by hand. |
| Rebuild without waiting for upstream | `bash update.sh --force` rebuilds and reinstalls even when upstream has not moved. Measured here: **2m56s** — the TypeScript build, every package pack, the bundled-runtime install, and electron-builder. |
| No concurrent runs | `~/.dsh/update.lock`; the whole run is appended to `~/.dsh/update.log`. |
| Untracked files do not block it | The clean-tree guard ignores untracked paths, because `local-setup/` is deliberately machine-local. |

**Known limit:** upstream edits to files this branch patches conflict, and no automation
can decide those. The delta is about 250 lines across 17 files in `apps/desktop`;
`scripts/package-target.ts` and `scripts/electron-builder-config.mjs` carry the highest
risk because the local unsigned-build mode sits in the packaging and signing paths
upstream also edits. Resolve once in a terminal; a merge keeps that resolution, so the
branch merges cleanly until upstream touches the same lines again.

The branch is merged onto upstream `master` (`c36a83ff6b`, version `0.1.7-alpha.1`).
Its delta is only the local ad-hoc build mode: the standard menus, the plugin-manager
window, the application icon, and the runtime smoke probe all come from upstream, which
now provides each of them. A merge run by `update.sh` cannot make conflict decisions
itself, which is exactly why a conflict aborts instead of guessing.

### Why the repository lives in `~/deepseek-harness`

macOS TCC protects `~/Documents`, and a `launchd` agent may not touch it — not the
script, not the repository. Measured while the clone was still there:

```
$ launchctl print gui/$(id -u)/ai.dsh.repo-update | grep 'last exit code'
	last exit code = 126
/bin/bash: ~/Documents/deepseek-harness/local-setup/check-update.sh: Operation not permitted

$ /bin/bash -c 'cd ~/Documents/deepseek-harness && git fetch upstream'   # same agent
fatal: Unable to read current working directory: Operation not permitted
```

The identical agent in `~/tcc-probe` answered `exec ok` and `git ok`, so the blocker is
the location rather than the script. Direct children of `$HOME` are outside TCC's
protected set; `~/Documents`, `~/Desktop`, and `~/Downloads` are inside it.

`~/Documents/deepseek-harness` remains as a symlink to the real directory so existing
shell habits keep working, but every script here resolves the real path from its own
location and the LaunchAgent is generated with it. Moving the repository back under
`~/Documents` reinstates the failure — the check would exit 126 silently every six hours,
which is why the failure is worth recognising: an agent that cannot reach the repository
exits `0` from its own guards, and only the exit code and a missing fetch tell you.

---

## What is installed where

| Path | What |
|---|---|
| `~/deepseek-harness/local-setup/` | **This directory.** The installer, the verifier, and the assets. Re-runnable. |
| `~/.dsh/bin/go-search-proxy.py` | The relay (installed from `assets/`). Holds no key. |
| `~/.dsh/bin/set-gui-path.sh` | Publishes the login PATH to the GUI session. |
| `~/.dsh/bin/opencode-usage.py` | Reports the OpenCode Go quota. Holds no key. |
| `~/Library/LaunchAgents/ai.dsh.opencode-go-search-relay.plist` | Auto-start + KeepAlive. |
| `~/Library/LaunchAgents/ai.dsh.gui-path.plist` | Runs `set-gui-path.sh` once per login. |
| `~/Library/LaunchAgents/ai.dsh.repo-update.plist` | Checks upstream every six hours and offers a rebuild. |
| `~/deepseek-harness/local-setup/update.sh` | Rebase → rebuild → sign → reinstall → relaunch. |
| `~/.dsh/update.log`, `~/.dsh/update-notified`, `~/.dsh/update.lock` | Update log, last offered upstream SHA, single-run lock. |
| `~/.dsh/settings.yaml` | `input: [text, image]` on the 4.1 entry, plus the `web-search-deepseek` block. |
| `~/.dsh/skills/` | Generated mirror of AgentKit's skills with Harness-valid names, plus the hand-authored `usage` bundle. |
| `/opt/homebrew/bin/pnpm` | The repo's pinned package manager, installed only when the machine had none. |
| `~/.dsh/go-search-proxy.log` | Relay log. |

Why not inside `/Applications/DeepSeek Harness.app`: **an app update replaces the whole
bundle**, so anything put there is lost — and adding files to a signed bundle can
invalidate its signature. `~/.dsh` is the Harness's own home and survives updates.

## Managing the service

```bash
launchctl kickstart -k gui/$(id -u)/ai.dsh.opencode-go-search-relay   # restart
launchctl print       gui/$(id -u)/ai.dsh.opencode-go-search-relay    # status
launchctl bootout     gui/$(id -u)/ai.dsh.opencode-go-search-relay    # stop
tail -f ~/.dsh/go-search-proxy.log                                    # log
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `read_image`: *does not declare image input* | `settings.yaml` lost the `input:` line (an update rewrote it). Re-run `install.sh`. |
| `web_search`: *not valid JSON* | The relay forwarded compressed bytes without the encoding header. Current relay asks for identity; if you edited it, re-run `install.sh`. |
| `web_search`: Cloudflare `error 1010` | A generic HTTP-library signature. The relay always sends `User-Agent: deepseek-harness/1.0`; if you replaced it, restore. |
| `web_search`: connection refused | The relay is down. `launchctl kickstart -k …` or re-run `install.sh`. |
| `400 MissingSessionID` | The session header was not added — the request did not go through the relay. Check `web-search-deepseek.baseURL`. |
| `CreditsError: Insufficient balance` | You are on `https://opencode.ai/zen/v1` (pay-as-you-go Zen), not Go. Go is a $10/mo subscription with its own limits; `/zen/go/v1` is the one with credit. |
| `ak: command not found` in a session | The running app still holds the old PATH. Quit and reopen DeepSeek Harness.app; the LaunchAgent only affects apps launched after it. |
| `node` / `pnpm`: `command not found` in a session | Same cause. Confirm with `launchctl getenv PATH`, then re-run `install.sh`. |
| A skill is missing from the session catalog | `~/.dsh/skills` is stale or a name was rejected. Re-run `install.sh`; `verify.sh` reports any name the Harness refuses. |
| Skills duplicated or stale after an AgentKit update | Re-run `install.sh`. The mirror refreshes the bundles it owns and prunes removed ones; your own bundles in `~/.dsh/skills` are never touched. |
| `/usage` shows nothing or an HTTP error | Run `~/.dsh/bin/opencode-usage.py` and read the message: `HTTP 401` means the key is not the Go one, `HTTP 404` means the endpoint moved. The plugin/allowance check needs no restart. |
| A quota plugin installed but no sidebar widget | The published plugins need `webServer`, which Desktop disables. They only render under `dsh --profile web`. |
| The update alert never appears | Check the agent is loaded (`launchctl print gui/$(id -u)/ai.dsh.repo-update`) and that upstream actually moved (`git -C ~/deepseek-harness rev-list --count HEAD..upstream/master`). A state already offered is not offered again; delete `~/.dsh/update-notified` to be asked again. |
| The update stopped with "needs attention" | The merge conflicted and was aborted; the installed app is untouched, and the next check offers that same update again. Resolve in a terminal: `git merge upstream/master`, fix the listed files, commit, then `bash local-setup/update.sh`. |
| The update stopped with "Uncommitted changes" | Tracked files are modified. Commit them to `desktop-local` or discard them; untracked paths such as `local-setup/` never block it. |
| An update seems stuck | `tail -f ~/.dsh/update.log`. A killed run leaves `~/.dsh/update.lock`; remove it only when no update is running. |

## Removing all of this

Only worth doing once the Harness sends the session header on every adapter
(upstream #5495) — at that point the relay is dead weight:

```bash
launchctl bootout gui/$(id -u)/ai.dsh.opencode-go-search-relay
launchctl bootout gui/$(id -u)/ai.dsh.gui-path
launchctl bootout gui/$(id -u)/ai.dsh.repo-update
rm ~/Library/LaunchAgents/ai.dsh.opencode-go-search-relay.plist
rm ~/Library/LaunchAgents/ai.dsh.gui-path.plist
rm ~/Library/LaunchAgents/ai.dsh.repo-update.plist
rm -rf ~/.dsh/bin ~/.dsh/skills ~/.dsh/update.log ~/.dsh/update-notified ~/deepseek-harness/local-setup
# then in ~/.dsh/settings.yaml: delete the `web-search-deepseek:` block,
# and (optionally) keep `input: [text, image]` — that one is still needed.
```

`~/.dsh/skills` holds a mirror of `~/.claude/skills` plus the hand-authored
`usage` bundle; deleting it removes all of them from Harness sessions and
changes nothing for Claude Code.

Backups of every `settings.yaml` edit sit beside it as
`settings.yaml.pre-install-*`, `…pre-4.1vision-*`, `…pre-websearch-*`.
