#!/usr/bin/env bash
# kubectl_completion.sh - Robust kubectl bash completion setup (idempotent)
# Source this from ~/.bashrc (appended automatically by setup step).
# It caches the generated completion to avoid repeatedly forking kubectl.

# Skip if not interactive
case $- in *i*) ;; *) return ;; esac

command -v kubectl >/dev/null 2>&1 || return 0

# Load base bash-completion if not yet
if ! type _init_completion >/dev/null 2>&1; then
  for f in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
    [ -r "$f" ] && . "$f" && break
  done
fi

# Cache file (refresh daily)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_FILE="$CACHE_DIR/kubectl_bash_completion"
REFRESH_SECS=86400
mkdir -p "$CACHE_DIR"

need_refresh=1
if [ -s "$CACHE_FILE" ]; then
  now=$(date +%s)
  mod=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  age=$(( now - mod ))
  if [ "$age" -lt "$REFRESH_SECS" ]; then
    need_refresh=0
  fi
fi

if [ $need_refresh -eq 1 ]; then
  if kubectl completion bash >"$CACHE_FILE.new" 2>/dev/null; then
    mv "$CACHE_FILE.new" "$CACHE_FILE"
  else
    rm -f "$CACHE_FILE.new"
  fi
fi

# Source cached completion if function still missing
if ! declare -F __start_kubectl >/dev/null 2>&1 && [ -r "$CACHE_FILE" ]; then
  . "$CACHE_FILE"
fi

# Fallback: direct generation if cache missing
if ! declare -F __start_kubectl >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source <(kubectl completion bash 2>/dev/null)
fi

# Register completion and alias (idempotent)
alias k=kubectl 2>/dev/null
complete -o default -F __start_kubectl kubectl 2>/dev/null || true
complete -o default -F __start_kubectl k 2>/dev/null || true
