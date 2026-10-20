#!/usr/bin/env bash
# lib/json.awk, lib/json.sh, lib/time.awk
. "$(dirname "$0")/../lib/harness.sh"

test_flatten_nested_document() {
  local out
  out=$(printf '{"a":{"b":[1,"x",true,null,{"c":-2.5e3}]},"d":"q\\"r","e":[],"f":{}}' | aionas_json_flatten)
  t_eq "$(printf '\to\t\na\to\t\na.b\ta\t\na.b.0\tn\t1\na.b.1\ts\tx\na.b.2\tb\ttrue\na.b.3\tz\t\na.b.4\to\t\na.b.4.c\tn\t-2.5e3\nd\ts\tq\\"r\ne\ta\t\nf\to\t')" "$out"
}

test_flatten_pretty_multiline() {
  local out
  out=$(printf '{\n  "methods": [\n    {"method_id": "handoff"}\n  ]\n}\n' | aionas_json_flatten | aionas_json_get methods.0.method_id)
  t_eq handoff "$out"
}

test_flatten_rejects_invalid() {
  local bad
  for bad in '{"a":}' '{"a":1,}' '[1 2]' '{"a":"x' 'tru' '{"a":1}x' '{a:1}'; do
    t_rc 2 aionas_json_flatten <<<"$bad" 2>/dev/null
  done
}

test_flatten_rejects_deep_nesting() {
  local s
  s=$(printf '%.0s[' $(seq 1 70))$(printf '%.0s]' $(seq 1 70))
  t_rc 2 aionas_json_flatten <<<"$s" 2>/dev/null
}

test_get_absent_path_fails() {
  t_rc 1 aionas_json_get b <<<"$(printf '{"a":1}' | aionas_json_flatten)"
}

test_escape_round_trip() {
  local s got
  s=$(printf 'a"b\\c\td\ne\001')
  got=$(aionas_json_escape "$s")
  t_eq '"a\"b\\c\td\ne\u0001"' "$got"
  t_eq "$s" "$(printf '{"k":%s}' "$got" | aionas_json_flatten | aionas_json_get k | aionas_json_unescape)"
  t_eq '"x\n"' "$(aionas_json_escape "$(printf 'x\nZ')" | sed 's/Z//')"
  t_eq '""' "$(aionas_json_escape '')"
}

test_time_epoch_and_day() {
  t_eq 1792532589 "$(awk -v mode=epoch -v iso=2026-10-20T21:43:09Z -f "$AIONAS_LIB/time.awk")"
  t_eq 1792521789 "$(awk -v mode=epoch -v iso=2026-10-20T21:43:09.123+03:00 -f "$AIONAS_LIB/time.awk")"
  t_eq 951782400 "$(awk -v mode=epoch -v iso=2000-02-29T00:00:00Z -f "$AIONAS_LIB/time.awk")"
  t_rc 2 awk -v mode=epoch -v iso=2026-13-01T00:00:00Z -f "$AIONAS_LIB/time.awk"
  t_rc 2 awk -v mode=epoch -v iso=yesterday -f "$AIONAS_LIB/time.awk"
  t_eq 2026-10-20 "$(aionas_day_utc 1792532589)"
  t_eq 2000-02-29 "$(aionas_day_utc 951782400)"
  t_eq 1970-01-01 "$(aionas_day_utc 0)"
}

t_main "$@"
