# Agent Note: Desktop packaging offers a local ad-hoc-signed macOS build

Status: implemented

English | [中文](2026-09-23-desktop-local-unsigned-build.zh.md)

## Problem

macOS packaging refuses to start without a Developer ID identity and a complete notarization credential set, and the fixed-target command additionally notarizes and staples a directory build. A developer without those credentials therefore cannot produce a runnable application for their own machine: the only unsigned mode, `DSH_DESKTOP_UNSIGNED=1`, is rejected for every non-Windows target, and Apple silicon refuses to execute arm64 code that carries no signature at all. The [electron desktop packaging decision](../architecture/2026-08-25-electron-desktop-packaging-and-updates.md) owns release identity and signing, and it makes unsigned macOS output impossible so that an unsigned artifact cannot pass for a release.

## Decision

`DSH_DESKTOP_LOCAL_UNSIGNED=1` selects a local macOS build that runs on the build host only.

- `prepare:dsh` ad-hoc signs every materialized Mach-O file instead of asserting a release identity, keeping the per-file identifiers and JIT entitlements.
- `package:mac:*:dir` skips the signing keychain, notarization, the mandatory-update policy, and the update channel; electron-builder disables code signing, hardened runtime, notarization, and DMG signing.
- Artifacts land in `.desktop-build/targets/mac-arm64/local-artifacts/`, beside the release and Windows-unsigned directories.
- The mode requires `--dir`. A disk image and a notarization ticket are release artifacts, so a local run that produced them would blur the line this mode exists to keep clear.
- The target dotenv file is optional: the application identifier and the flag come from the caller, because a local build owns no release settings to read.

Every credential requirement outside the flag is unchanged, and the built application carries no release identity, ticket, update channel, or completion record.

## Alternatives considered

**Reuse `DSH_DESKTOP_UNSIGNED` for macOS.** That flag means "produce an unsigned Windows artifact": its artifacts carry an `-unsigned` name and its command builds a full installer. Sharing it would make one flag mean two artifact kinds and would weaken the Windows-specific credential stripping.

**Accept a certificate from the login keychain.** A self-signed identity there produces a signature Gatekeeper rejects on another machine and this repository cannot verify. An ad-hoc signature states plainly that the build is local.

**Support a local DMG or ZIP.** Both need a signature, and distribution needs a ticket. Producing them locally would either require the credentials this mode exists to avoid or emit an artifact indistinguishable from a release.

**Let the developer run `codesign --deep` after a failed build.** The build stops before packaging, so there is no application to sign, and `--deep` re-signs nested code without the per-file identifiers and entitlements the runtime uses.

## Consequences

- A developer on Apple silicon can build and run the application without Apple credentials; the build still needs the normal toolchain, Python, and network access for Electron and the bundled runtime.
- The mode never satisfies release qualification: it writes no completion record, embeds no update channel or policy, and signs with no identity.
- Unit coverage pins the artifact directory, the dropped identity, notarization, and update fields, the missing-dotenv path, and the rejection of a local build without `--dir`.
- The package command rejects the mode for a non-macOS target, so the flag cannot silently weaken a Windows or Linux build.
