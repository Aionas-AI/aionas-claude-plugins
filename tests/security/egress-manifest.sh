#!/usr/bin/env bash
# Prints what every plugin can run and send, one sorted line each:
#   file <path>              every file a plugin ships (a new script shows up here)
#   hook <command>           every hooks.json command and module
#   http <METHOD> <path>     every request to the enrolled gateway
#   net <path>: <tool>       any other network tool or API outside lib/http.sh
#   mod <path>: <api>        every privileged mod API ($.http, $.process, $.fs)
# tests/unit/egress-manifest.test.sh compares it with security/egress-manifest.txt,
# so a change to what reaches a customer computer fails CI until that file is
# updated in the same PR, where the code owner sees it.
set -u
cd "${1:-$(dirname "$0")/../..}" || exit 1
LC_ALL=C
export LC_ALL

code() { grep -vE '^[[:space:]]*(#|//)' "$1"; }

{
  find plugins -type f ! -path '*/tests/*' ! -path '*/docs/*' | sed 's/^/file /'
  for f in plugins/*/hooks/hooks.json; do
    grep -oE '"(command|modules)": *("[^"]*(\\"[^"]*)*"|\[[^]]*\])' "$f" | sed "s|^|hook $f |"
  done
  find plugins -type f ! -path '*/tests/*' ! -path '*/docs/*' | while IFS= read -r f; do
    code "$f" | grep -oE 'aionas_http (GET|POST|PUT|PATCH|DELETE) [^ ]+' | sed "s|^aionas_http |http |"
    case "$f" in */lib/http.sh) continue ;; esac
    code "$f" | grep -oE '(^|[^A-Za-z_])(curl|wget|socat|telnet|ssh|scp|Invoke-WebRequest|Invoke-RestMethod)([^A-Za-z_-]|$)|/dev/(tcp|udp)/|(^|[^.A-Za-z_])fetch\(|XMLHttpRequest|WebSocket' |
      sed -E "s/^[^A-Za-z/]*//; s/[^A-Za-z(/]*$//; s|^|net $f: |"
    code "$f" | grep -oE '\$\.(http|process|fs)\.[A-Za-z]+' | sed "s|^|mod $f: |"
  done
} | sort -u
