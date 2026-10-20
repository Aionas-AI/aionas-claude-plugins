#!/usr/bin/env bash
# W24-P2 with the real curl: a gateway that accepts and never answers costs
# at most 5 s, and the cached policy stays in force.
. "$(dirname "$0")/../lib/harness.sh"

test_hanging_gateway_costs_at_most_5s() {
  command -v python3 >/dev/null || { echo "    skip: no python3"; return 0; }
  command -v curl >/dev/null || { echo "    skip: no curl"; return 0; }
  unset AIONAS_CURL
  local portf pid port t1 t2
  portf=$(mktemp "$T_ROOT/port.XXXXXX")
  python3 -I -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
conns = []
end = time.time() + 20
s.settimeout(0.5)
while time.time() < end:
    try:
        c, _ = s.accept(); conns.append(c)
    except socket.timeout:
        pass
' "$portf" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$portf" ] && break; sleep 0.2; done
  port=$(cat "$portf")
  t_enroll "http://127.0.0.1:$port"
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\tnoisy_guard\toff\t0\t0\t0\t0\n' >"$(aionas_savings_dir)/policy.cache"
  t1=$(date +%s)
  t_rc 1 aionas_policy_sync
  t2=$(date +%s)
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ $((t2 - t1)) -le 6 ] || t_fail "sync took $((t2 - t1)) s"
  [ $((t2 - t1)) -ge 4 ] || t_fail "sync returned in $((t2 - t1)) s: the hang was not exercised"
  t_eq off "$(aionas_policy_state noisy_guard)"
  t_eq 000 "$(cut -d' ' -f2 "$(aionas_savings_dir)/sync.status")"
}

t_main "$@"
