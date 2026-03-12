#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <base-sha> [head-sha]" >&2
  exit 64
fi

base_sha="$1"
head_sha="${2:-HEAD}"

if [[ -z "$base_sha" || "$base_sha" == "0000000000000000000000000000000000000000" ]]; then
  base_sha="$(git hash-object -t tree /dev/null)"
fi

git diff --name-only --diff-filter=AMR "$base_sha" "$head_sha" -- '*.swift' | sed '/^$/d'
