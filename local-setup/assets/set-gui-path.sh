#!/bin/bash
# Publish the login shell's PATH into the GUI login session.
#
# launchd gives every app opened from Finder only /usr/bin:/bin:/usr/sbin:/sbin,
# so DeepSeek Harness.app -- and therefore every shell call its agent makes --
# cannot see Homebrew (node, pnpm, git), /usr/local/bin, or ~/.local/bin (ak).
# The Harness shell tool inherits the application's environment, so this one
# setting is what makes those commands reachable from a session.
#
# Re-run any time: bash ~/.dsh/bin/set-gui-path.sh
set -euo pipefail

LABEL="$(/usr/bin/basename "${BASH_SOURCE[0]}")"

# The user's login shell is the source of truth for their developer PATH.
LOGIN_PATH="$(/bin/zsh -lc 'printf %s "$PATH"' 2>/dev/null || true)"
if [ -z "$LOGIN_PATH" ]; then
  # Fall back to the system list if zsh is unavailable or its rc files fail.
  LOGIN_PATH="$(/usr/bin/tr '\n' ':' < /etc/paths | /usr/bin/sed 's/:$//')"
fi

# ~/.local/bin carries the AgentKit CLI (ak) and is not in the login PATH.
case ":$LOGIN_PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) LOGIN_PATH="$HOME/.local/bin:$LOGIN_PATH" ;;
esac

/bin/launchctl setenv PATH "$LOGIN_PATH"
printf '%s: gui PATH = %s\n' "$LABEL" "$LOGIN_PATH"
