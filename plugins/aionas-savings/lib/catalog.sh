# aionas-savings closed lists, matching the gateway contract
# (docs/openapi/paths/management/aionassavings.yaml, wave 24).

# Every method id the server knows. cache_guard is required: always on,
# never overridden or released.
AIONAS_METHODS="handoff effort_default subagent_sonnet unused_services noisy_guard output_store write_minimum cache_alert seat_fit cache_guard tool_search dispatcher"
AIONAS_REQUIRED_METHODS="cache_guard"

# The plugin's counters (AIO-855): numbers only, summed per UTC day.
AIONAS_COUNTERS="fired skipped bypass"

# aionas_is_method ID / aionas_is_required ID / aionas_is_counter NAME
aionas_is_method() { _in_list "$1" $AIONAS_METHODS; }
aionas_is_required() { _in_list "$1" $AIONAS_REQUIRED_METHODS; }
aionas_is_counter() { _in_list "$1" $AIONAS_COUNTERS; }

_in_list() {
  _il_x=$1; shift
  [ -n "$_il_x" ] || return 1
  for _il_v in "$@"; do [ "$_il_v" = "$_il_x" ] && return 0; done
  return 1
}
