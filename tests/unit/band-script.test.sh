#!/usr/bin/env bash
# The aionas mod band's script side (wave-24 mod spec §4, §5): aionas-bypass.sh
# --band and --end, the "request pending" record, and the hourly policy sync in
# hooks/counters-flush.sh (AIO-855, AIO-859; W24-1, W24-4, W24-P2).
. "$(dirname "$0")/../lib/harness.sh"
BYPASS="$T_PLUGIN/commands/aionas-bypass.sh"
FLUSH="$T_PLUGIN/hooks/counters-flush.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
TAB=$(printf '\t')

band() { AIONAS_SESSION_ID=${SID:-s1} TZ=${TZ:-UTC} bash "$BYPASS" --band; }
line() { printf '%s\n' "$1" | grep "^$2$TAB" | head -1; }
method_line() { band | grep "^method${TAB}$1${TAB}"; }
answer() { # STATUS JSON_STATUS ID
  local f; f=$(mktemp "$T_ROOT/ans.XXXXXX")
  printf '{"id":"%s","user_id":"u1","method_id":"x","status":"%s"}' "$3" "$2" >"$f"
  export FAKE_CURL_STATUS=$1 FAKE_CURL_BODY=$f
}
cache() { # cache lines (V/F/M/P/O, tab separated) -> policy.cache, and as the s1 pin
  aionas_mkdir "$(aionas_savings_dir)/sessions"
  printf '%b' "$1" >"$(aionas_savings_dir)/policy.cache"
  cp "$(aionas_savings_dir)/policy.cache" "$(aionas_savings_dir)/sessions/s1.cache"
}
policy_json() { aionas_mkdir "$(aionas_savings_dir)"; printf '%s' "$1" >"$(aionas_savings_dir)/policy.json"; }

test_band_with_nothing_cached_is_the_local_half_all_on_and_offline() {
  export AIONAS_NOW=$T0
  local out; out=$(band)
  t_eq "$(printf 'clock\t%s\t0' "$T0")" "$(line "$out" clock)"
  t_lacks "$out" "me$TAB"
  t_lacks "$out" "savings$TAB"
  t_eq 6 "$(printf '%s\n' "$out" | grep -c "^method$TAB")"
  t_eq "$(printf 'method\thandoff\ton\t1\t1\t0\t0\t0\t0')" "$(line "$out" "method${TAB}handoff")"
  t_eq "$(printf 'method\toutput_trim\toff\t0\t1\t0\t0\t0\t0')" "$(line "$out" "method${TAB}output_trim")" "off by default (AIO-883)"
  t_lacks "$out" cache_guard
  t_lacks "$out" cache_alert
  t_lacks "$out" seat_fit
  t_eq "$(printf 'window\t-\t0\t-')" "$(line "$out" window)"
  t_eq "$(printf 'compact_at\t200000\t55')" "$(line "$out" compact_at)"
  t_eq "$(printf 'gateway_host\t-')" "$(line "$out" gateway_host)"
  t_eq 0 "$(t_calls)"
}

test_band_order_is_the_chip_order() {
  t_eq "effort_default subagent_sonnet output_trim handoff unused_services write_minimum" \
    "$(band | awk -F '\t' '$1 == "method" { printf "%s%s", (n++ ? " " : ""), $2 }')"
}

test_band_me_and_savings_come_from_policy_json_sanitized() {
  export AIONAS_NOW=$T0
  local long; long=$(printf 'x%.0s' $(seq 1 100))
  policy_json '{"methods":[],"me":{"display_name":"Noa \"N\"\tLevi\nנועה","org_name":"'"$long"'","role":"member","lead_name":null,"computer_name":""},
    "savings":{"as_of":"2026-10-20T10:05:00Z","money_kind":"usd","today_usd":3.8,"since_on_usd":null,"today_tokens":1400000,"since_on_tokens":9000000,"since_on_date":"2026-10-08","tier":"estimated"}}'
  local out; out=$(band)
  t_eq "$(printf 'me\tNoa "N" Levi \327\240\327\225\327\242\327\224\t%s\tmember\t-\t-' "$(printf 'x%.0s' $(seq 1 80))")" "$(line "$out" me)"
  t_eq "$(printf 'savings\tusd\t3.8\t-\t1400000\t9000000\t2026-10-08\t-\t-\t-\t%s' $((T0 + 300)))" "$(line "$out" savings)"
  t_eq 0 "$(t_calls)"
}

test_band_savings_since_on_negatives_nulls_and_potential() { # AIO-867
  policy_json '{"savings":{"money_kind":"api_value","today_usd":null,"since_on_usd":-2.5,"today_tokens":null,"since_on_tokens":-120000,"since_on_date":"2026-10-21","could_save_usd":61.2,"could_save_tokens":2100000,"counted_days":3,"as_of":"2026-10-20T10:00:00Z"}}'
  t_eq "$(printf 'savings\tapi_value\t-\t-2.5\t-\t-120000\t2026-10-21\t61.2\t2100000\t3\t%s' "$T0")" "$(line "$(band)" savings)"
  policy_json '{"savings":{"money_kind":"usd","since_on_tokens":1.5,"counted_days":"3","could_save_tokens":12345678901234567}}'
  t_eq "$(printf 'savings\tusd\t-\t-\t-\t-\t-\t-\t-\t-\t0')" "$(line "$(band)" savings)"
}

test_band_names_are_cut_at_80_characters_not_bytes() {
  local heb; heb=$(printf '\\u05d0%.0s' $(seq 1 90))
  policy_json '{"me":{"display_name":"'"$heb"'","org_name":"Acme","role":"member","lead_name":"Omer","computer_name":"mbp"}}'
  local name; name=$(band | awk -F '\t' '$1 == "me" { print $2 }')
  t_eq 80 "$(printf '%s' "$name" | awk '{ n = gsub(/\327\220/, ""); print n }')"
  t_eq 160 "$(printf '%s' "$name" | LC_ALL=C wc -c | tr -d ' ')"
}

test_band_subscription_savings_and_malformed_blocks() {
  policy_json '{"me":{"org_name":"Acme"},"savings":{"money_kind":"api_value","today_usd":5.1,"since_on_usd":40,"today_tokens":1400000,"since_on_tokens":9000000,"since_on_date":"2026-10-08","as_of":"bad"}}'
  local out; out=$(band)
  t_lacks "$out" "me$TAB" "no display name, no me line"
  t_eq "$(printf 'savings\tapi_value\t5.1\t40\t1400000\t9000000\t2026-10-08\t-\t-\t-\t0')" "$(line "$out" savings)"
  policy_json '{"savings":{"money_kind":"eur","today_usd":1}}'
  t_lacks "$(band)" "savings$TAB"
  policy_json 'not json'
  t_lacks "$(band)" "savings$TAB"
}

test_band_method_states_from_the_pin_local_overrides_requests_and_counters() {
  export AIONAS_NOW=$T0
  cache "V\t1\nF\t$((T0 - 60))\nM\toutput_trim\ton\t0\t0\t1\t0\nM\twrite_minimum\ton\t0\t1\t1\t1\nM\thandoff\toff\t0\t1\t1\t0\nP\thandoff\tthreshold_tokens\tn\t150000\nP\thandoff\tidle_minutes\tn\t40\nO\teffort_default\tself\t$((T0 - 600))\t$((T0 + 3000))\tovr_1\nO\tunused_services\trequested\t0\t0\tovr_2\n"
  aionas_override_local_add subagent_sonnet 1800 self
  mkdir -p "$(aionas_savings_dir)/counters"
  printf '2026-10-20\toutput_trim\tfired\t3\n2026-10-20\toutput_trim\tfired\t1\n2026-10-20\toutput_trim\tbypass\t1\n2026-10-19\toutput_trim\tfired\t9\n' >"$(aionas_savings_dir)/counters/queue.tsv"
  printf '2026-10-20\teffort_default\tfired\t2\n' >"$(aionas_savings_dir)/counters/pending.tsv"
  local out; out=$(band)
  t_eq "$(printf 'method\toutput_trim\ton\t1\t0\t0\t0\t0\t4')" "$(line "$out" "method${TAB}output_trim")" "blocked self-override, 4 fired today"
  t_eq "$(printf 'method\twrite_minimum\toff\t0\t1\t1\t0\t0\t0')" "$(line "$out" "method${TAB}write_minimum")" "released"
  t_eq "$(printf 'method\thandoff\toff\t0\t1\t0\t0\t0\t0')" "$(line "$out" "method${TAB}handoff")" "off by policy"
  t_eq "$(printf 'method\teffort_default\ton\t0\t1\t0\t%s\t0\t2' $((T0 + 3000)))" "$(line "$out" "method${TAB}effort_default")" "server bypass in force"
  t_eq "$(printf 'method\tsubagent_sonnet\ton\t0\t1\t0\t%s\t0\t0' $((T0 + 1800)))" "$(line "$out" "method${TAB}subagent_sonnet")" "local bypass"
  t_eq "$(printf 'method\tunused_services\ton\t1\t1\t0\t0\t1\t0')" "$(line "$out" "method${TAB}unused_services")" "request pending"
  t_eq "$(printf 'compact_at\t150000\t40')" "$(line "$out" compact_at)"
}

test_band_window_and_session_grant() {
  export AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)/sessions"
  printf '%s\t%s\txhigh\tself\t-\n' $((T0 - 60)) $((T0 + 540)) >"$(aionas_savings_dir)/effort-window"
  printf 'xhigh\n' >"$(aionas_savings_dir)/sessions/s1.effort"
  t_eq "$(printf 'window\txhigh\t%s\txhigh' $((T0 + 540)))" "$(line "$(band)" window)"
  export AIONAS_NOW=$((T0 + 600))
  t_eq "$(printf 'window\t-\t0\txhigh')" "$(line "$(band)" window)" "an ended window is closed"
}

test_band_handoff_line_from_the_session_state() { # AIO-874
  t_eq "$(printf 'handoff\t-\t0\t0\t0\t0')" "$(line "$(band)" handoff)" "no state"
  local d; d="$(aionas_savings_dir)/handoff"; aionas_mkdir "$d"
  printf 'armed\t100\t30000\t1792000000\n' >"$d/s1.state"
  t_eq "$(printf 'handoff\tarmed\t1792000000\t0\t0\t100')" "$(line "$(band)" handoff)"
  printf 'delivered\t100\t30000\t1792003600\n' >"$d/s1.state"
  t_eq "$(printf 'handoff\tdelivered\t0\t1792003600\t0\t100')" "$(line "$(band)" handoff)" "no doc yet"
  printf '# doc\n' >"$d/handoff-s1.md"
  t_eq "$(printf 'handoff\tdelivered\t0\t1792003600\t1\t100')" "$(line "$(band)" handoff)"
  printf 'delivered\t100\t30000\n' >"$d/s1.state"
  t_eq "$(printf 'handoff\tdelivered\t0\t0\t1\t100')" "$(line "$(band)" handoff)" "an older state line"
  printf 'weird\t100\t1\t999\n' >"$d/s1.state"
  t_eq "$(printf 'handoff\t-\t0\t0\t1\t100')" "$(line "$(band)" handoff)"
  t_eq "$(printf 'handoff\t-\t0\t0\t0\t0')" "$(SID=s2 band | grep "^handoff$TAB")" "another session's state is not read"
}

test_band_gateway_host_and_local_offset() {
  t_enroll "https://GW.Example.test:8443/base/path"
  t_eq "$(printf 'gateway_host\tgw.example.test:8443')" "$(line "$(band)" gateway_host)"
  t_eq 10800 "$(TZ=Asia/Jerusalem band | awk -F '\t' '$1 == "clock" { print $3 }')"
  t_eq -18000 "$(TZ=EST band | awk -F '\t' '$1 == "clock" { print $3 }')"
  t_eq 0 "$(t_calls)" "--band never calls the gateway"
}

test_blocked_bypass_is_recorded_as_a_pending_request_until_the_next_sync() {
  t_enroll; export AIONAS_NOW=$T0
  cache "V\t1\nF\t$((T0 - 60))\nM\toutput_trim\ton\t0\t0\t1\t0\n"
  answer 202 requested ovr_c
  local out; out=$(AIONAS_SESSION_ID=s1 bash "$BYPASS" output_trim 1h)
  t_contains "$out" "sent for approval"
  t_eq "$(printf 'method\toutput_trim\ton\t1\t0\t0\t0\t1\t0')" "$(method_line output_trim)"
  # A newer sync that no longer lists the request (approved or declined) wins.
  cache "V\t1\nF\t$((T0 + 60))\nM\toutput_trim\ton\t0\t0\t1\t0\n"
  export AIONAS_NOW=$((T0 + 120))
  t_eq "$(printf 'method\toutput_trim\ton\t1\t0\t0\t0\t0\t0')" "$(method_line output_trim)"
}

test_blocked_bypass_while_offline_is_pending_too() {
  t_enroll; export AIONAS_NOW=$T0 FAKE_CURL_EXIT=7
  cache "V\t1\nF\t$((T0 - 60))\nM\toutput_trim\ton\t0\t0\t1\t0\n"
  AIONAS_SESSION_ID=s1 bash "$BYPASS" output_trim 1h >/dev/null
  t_eq 1 "$(method_line output_trim | cut -f8)"
}

test_end_ends_my_local_bypass_at_once_with_no_network_call_and_no_counter() {
  t_enroll; export AIONAS_NOW=$T0; answer 201 self ovr_a
  cache "V\t1\nF\t$((T0 - 60))\nM\toutput_trim\ton\t0\t1\t1\t0\n" # off by default (AIO-883)
  AIONAS_SESSION_ID=s1 bash "$BYPASS" output_trim 1h >/dev/null
  t_eq 1 "$(t_calls)"
  t_not aionas_policy_active output_trim s1
  local q; q=$(cat "$(aionas_savings_dir)/counters/queue.tsv")
  local out; out=$(AIONAS_SESSION_ID=s1 bash "$BYPASS" --end output_trim)
  t_eq 0 $?
  t_contains "$out" "output_trim is back on for you on this computer"
  t_eq 1 "$(t_calls)" "--end makes no network call"
  t_ok aionas_policy_active output_trim s1
  t_eq "$q" "$(cat "$(aionas_savings_dir)/counters/queue.tsv")" "the bypass counter is unchanged"
  t_eq "$(printf 'method\toutput_trim\ton\t1\t1\t0\t0\t0\t0')" "$(method_line output_trim)"
}

test_end_also_ends_the_server_row_in_the_pins_and_after_a_later_sync() {
  export AIONAS_NOW=$T0
  local o; o="O\toutput_trim\tself\t$((T0 - 600))\t$((T0 + 3000))\tovr_1\n"
  cache "V\t1\nF\t$((T0 - 60))\nM\toutput_trim\ton\t0\t1\t1\t0\n$o"
  cp "$(aionas_savings_dir)/sessions/s1.cache" "$(aionas_savings_dir)/sessions/s2.cache"
  t_not aionas_policy_active output_trim s2
  AIONAS_SESSION_ID=s1 bash "$BYPASS" --end guard >/dev/null
  t_ok aionas_policy_active output_trim s1
  t_ok aionas_policy_active output_trim s2
  t_ok aionas_policy_active output_trim
  # The server keeps its row until its own end: a later sync brings it back,
  # and the band's next read (or the hourly flush) strips it again.
  export AIONAS_NOW=$((T0 + 60))
  cache "V\t1\nF\t$((T0 + 60))\nM\toutput_trim\ton\t0\t1\t1\t0\n$o"
  t_not aionas_policy_active output_trim s1
  t_eq 1 "$(method_line output_trim | cut -f4)"
  t_ok aionas_policy_active output_trim s1
  t_ok aionas_policy_active output_trim
  # A new bypass made after the end is not touched.
  cache "V\t1\nF\t$((T0 + 60))\nM\toutput_trim\ton\t0\t1\t1\t0\nO\toutput_trim\tself\t$((T0 + 30))\t$((T0 + 3600))\tovr_2\n"
  t_eq 0 "$(method_line output_trim | cut -f4)"
}

test_end_without_a_bypass_required_and_unknown() {
  local out; out=$(bash "$BYPASS" --end output_trim)
  t_eq 0 $?
  t_contains "$out" "was not bypassed"
  t_rc 1 bash "$BYPASS" --end cache_guard >/dev/null
  t_rc 2 bash "$BYPASS" --end nonsense >/dev/null
  t_rc 2 bash "$BYPASS" --end >/dev/null
  t_eq 0 "$(t_calls)"
}

test_counters_flush_refreshes_the_policy_at_most_hourly() {
  t_enroll; export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$T_REPO/tests/fixtures/policy.json" AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)"
  printf '%s 200\n' $((T0 - 3700)) >"$(aionas_savings_dir)/sync.status"
  printf '{}' | bash "$FLUSH"
  t_eq 1 "$(t_calls)"
  t_eq GET "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/policy "$(t_call 1 url)"
  t_ok test -f "$(aionas_savings_dir)/policy.json"
  export AIONAS_NOW=$((T0 + 600))
  printf '{}' | bash "$FLUSH"
  t_eq 1 "$(t_calls)" "not again within the hour"
}

test_counters_flush_with_no_sync_on_record_leaves_it_to_session_start() {
  t_enroll; export FAKE_CURL_STATUS=200 AIONAS_NOW=$T0
  printf '{}' | bash "$FLUSH"
  t_eq 0 "$(t_calls)"
}

test_counters_flush_skips_the_counters_when_the_sync_finds_the_gateway_down() {
  t_enroll; export FAKE_CURL_EXIT=28 AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)/counters"
  printf '%s 200\n' $((T0 - 3700)) >"$(aionas_savings_dir)/sync.status"
  printf '2026-10-20\toutput_trim\tfired\t2\n' >"$(aionas_savings_dir)/counters/queue.tsv"
  printf '{}' | bash "$FLUSH"
  t_eq 1 "$(t_calls)" "one try, then the hook ends within its timeout"
  t_ok test -f "$(aionas_savings_dir)/counters/queue.tsv"
}

test_counters_flush_keeps_an_early_end_after_its_sync() {
  t_enroll; export AIONAS_NOW=$T0
  local f; f=$(mktemp "$T_ROOT/pol.XXXXXX")
  printf '{"methods":[{"method_id":"output_trim","state":"on","required":false,"self_override_allowed":true,"self_release_allowed":true}],"overrides":[{"id":"o1","method_id":"output_trim","status":"self","from_at":"2026-10-20T09:50:00Z","until_at":"2026-10-20T10:50:00Z"}]}' >"$f"
  export FAKE_CURL_STATUS=200 FAKE_CURL_BODY=$f
  bash "$BYPASS" --end output_trim >/dev/null
  printf '%s 200\n' $((T0 - 3700)) >"$(aionas_savings_dir)/sync.status"
  printf '{}' | bash "$FLUSH"
  t_eq GET "$(t_call 1 method)"
  t_ok aionas_policy_active output_trim
}

t_main "$@"
