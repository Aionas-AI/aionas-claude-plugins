#!/usr/bin/env bash
# aionas-savings hook: output-store (PostToolUse). Owner: AIO-860.
# The entry hooks.json registers; the store itself is posttool-store.sh.
exec bash "$(dirname "$0")/posttool-store.sh"
