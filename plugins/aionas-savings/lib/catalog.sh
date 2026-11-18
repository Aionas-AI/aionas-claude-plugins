# aionas-savings closed lists, matching the gateway contract
# (docs/openapi/paths/management/aionassavings.yaml, wave 24).

# Every method id the server knows. cache_guard is required: always on,
# never overridden or released. Tool output trimming is no longer a method
# of the plugin (0.6.1, AIO-1073).
AIONAS_METHODS="handoff effort_default subagent_sonnet unused_services write_minimum cache_alert seat_fit cache_guard tool_search dispatcher"
AIONAS_REQUIRED_METHODS="cache_guard"

# subagent_sonnet's model: the alias the one install writes too.
AIONAS_SUBAGENT_MODEL=sonnet
# Methods that are off when the policy has no row for them (every other
# method is on: W24-1). None since 0.6.1.
AIONAS_DEFAULT_OFF_METHODS=""

# The plugin's counters (AIO-855): numbers only, summed per UTC day.
# compact_pressed (AIO-1023, handoff only): one per compaction started from the
# band's /compact button; the gateway release v0.31.0 accepts the name.
AIONAS_COUNTERS="fired skipped bypass compact_pressed"

# aionas_is_method ID / aionas_is_required ID / aionas_is_default_off ID /
# aionas_is_counter NAME
aionas_is_method() { _in_list "$1" $AIONAS_METHODS; }
aionas_is_required() { _in_list "$1" $AIONAS_REQUIRED_METHODS; }
aionas_is_default_off() { _in_list "$1" $AIONAS_DEFAULT_OFF_METHODS; }
aionas_is_counter() { _in_list "$1" $AIONAS_COUNTERS; }

_in_list() {
  _il_x=$1; shift
  [ -n "$_il_x" ] || return 1
  for _il_v in "$@"; do [ "$_il_v" = "$_il_x" ] && return 0; done
  return 1
}
