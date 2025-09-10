#!/usr/bin/env bash
# enable_completions.sh - Convenience loader for kubectl, docker, and minikube bash completion.
# Source this from ~/.bashrc (preferred) instead of embedding large blocks.

case $- in *i*) ;; *) return ;; esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for helper in kubectl_completion.sh docker_completion.sh minikube_completion.sh; do
  path="$SCRIPT_DIR/$helper"
  [ -r "$path" ] && . "$path"
done

# Optional short aliases (idempotent)
command -v kubectl >/dev/null 2>&1 && alias k=kubectl 2>/dev/null || true
command -v minikube >/dev/null 2>&1 && alias mk=minikube 2>/dev/null || true
