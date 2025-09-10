#!/usr/bin/env bash
# minikube_completion.sh - Minikube CLI bash completion with caching

case $- in *i*) ;; *) return ;; esac
command -v minikube >/dev/null 2>&1 || return 0

if ! type _init_completion >/dev/null 2>&1; then
  for f in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
    [ -r "$f" ] && . "$f" && break
  done
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_FILE="$CACHE_DIR/minikube_bash_completion"
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
  if minikube completion bash >"$CACHE_FILE.new" 2>/dev/null; then
    mv "$CACHE_FILE.new" "$CACHE_FILE"
  else
    rm -f "$CACHE_FILE.new"
  fi
fi

# shellcheck disable=SC1090
[ -r "$CACHE_FILE" ] && . "$CACHE_FILE"
