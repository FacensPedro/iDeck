#!/usr/bin/env bash
# Ensure Wine's parser generator is GNU Bison 3+ rather than Apple's Bison 2.3.
# Source this script when building locally so PATH changes reach Wine configure.
set -euo pipefail

ideck_bison_compatible() {
  local executable="${1:-}"
  local banner
  [[ -n "$executable" && -x "$executable" ]] || return 1
  banner="$("$executable" --version 2>/dev/null)" || return 1
  banner="${banner%%$'\n'*}"
  [[ "$banner" =~ ([0-9]+)\.([0-9]+) ]] || return 1
  (( 10#${BASH_REMATCH[1]} >= 3 ))
}

candidate="$(command -v bison || true)"
if ! ideck_bison_compatible "$candidate"; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Wine 11.4 requires GNU Bison >= 3.0; the current bison is missing or too old and Homebrew is unavailable." >&2
    return 2 2>/dev/null || exit 2
  fi
  # Homebrew may return an error for an uninstalled formula. An empty
  # prefix is not a usable toolchain; install before querying again.
  homebrew_bison="$(brew --prefix bison 2>/dev/null || true)"
  if ! ideck_bison_compatible "$homebrew_bison/bin/bison"; then
    echo "Installing modern GNU Bison for Wine 11.4 (Apple's /usr/bin/bison is too old)."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install bison
    homebrew_bison="$(brew --prefix bison)"
  fi
  if ! ideck_bison_compatible "$homebrew_bison/bin/bison"; then
    echo "ERROR: Homebrew bison is absent or older than 3.0 at $homebrew_bison/bin/bison." >&2
    return 2 2>/dev/null || exit 2
  fi
  export PATH="$homebrew_bison/bin:$PATH"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$homebrew_bison/bin" >> "$GITHUB_PATH"
  fi
fi

candidate="$(command -v bison || true)"
if ! ideck_bison_compatible "$candidate"; then
  echo "ERROR: Wine Bison preflight did not select GNU Bison >= 3.0." >&2
  return 2 2>/dev/null || exit 2
fi
echo "Wine 11.4 parser preflight: $("$candidate" --version | head -n 1) ($candidate)"
