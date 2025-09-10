#!/usr/bin/env bash
# docker_completion.sh - Docker CLI bash completion with simple caching.
# Source from ~/.bashrc or via scripts/enable_completions.sh

case $- in *i*) ;; *) return ;; esac
command -v docker >/dev/null 2>&1 || return 0

# Load base bash-completion if not already
if ! type _init_completion >/dev/null 2>&1; then
  for f in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
    [ -r "$f" ] && . "$f" && break
  done
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_FILE="$CACHE_DIR/docker_bash_completion"
REFRESH_SECS=86400
mkdir -p "$CACHE_DIR"

need_refresh=1
if [ -s "$CACHE_FILE" ]; then
  now=$(date +%s)
  mod=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  age=$(( now - mod ))
  [ "$age" -lt "$REFRESH_SECS" ] && need_refresh=0
fi

if [ $need_refresh -eq 1 ]; then
  if docker completion bash >"$CACHE_FILE.new" 2>/dev/null; then
    mv "$CACHE_FILE.new" "$CACHE_FILE"
  else
    rm -f "$CACHE_FILE.new"
  fi
fi

# shellcheck disable=SC1090
[ -r "$CACHE_FILE" ] && . "$CACHE_FILE"
