# aionas-savings: the GET /enroll/v1/savings/policy answer, flattened by
# json.awk, -> the policy cache (load with: awk -f time.awk -f policy.awk).
#   V 1
#   F <fetched epoch>
#   M <method> <on|off> <required> <self_override> <self_release> <released>
#   P <method> <param path> <type> <raw value>
#   O <method> <status> <from epoch|0> <until epoch|0> <id>
# (tab separated; flags are 1/0). Methods outside the catalog and malformed
# rows are skipped. Exit 2 (write nothing) when there is no methods array.
BEGIN {
  FS = "\t"
  nm = split(methods, ml, " "); for (k = 1; k <= nm; k++) known[ml[k]] = 1
  split("self requested approved declined released", sl, " "); for (k in sl) okstatus[sl[k]] = 1
}
{
  p = $1; t = $2; v = $3
  if (p == "methods" && t == "a") have = 1
  np = split(p, seg, ".")
  if (seg[1] == "methods" && np >= 3) {
    n = seg[2]; f = seg[3]; mi[n] = 1
    if (np == 3) mv[n, f] = (t == "s" || t == "b") ? v : "\001"
    else if (f == "params" && (t == "s" || t == "n" || t == "b")) {
      key = seg[4]; for (k = 5; k <= np; k++) key = key "." seg[k]
      pc[n]++; pk[n, pc[n]] = key; pt[n, pc[n]] = t; pv[n, pc[n]] = v
    }
  } else if (seg[1] == "overrides" && np == 3) {
    n = seg[2]; oi[n] = 1; ov[n, seg[3]] = (t == "s") ? v : ""
  }
}
function flag(x) { return x == "true" ? 1 : (x == "false" ? 0 : -1) }
END {
  if (!have) exit 2
  print "V\t1"
  print "F\t" now
  for (n in mi) {
    id = mv[n, "method_id"]; st = mv[n, "state"]
    if (!(id in known) || (st != "on" && st != "off")) continue
    rq = flag(mv[n, "required"]); so = flag(mv[n, "self_override_allowed"]); sr = flag(mv[n, "self_release_allowed"])
    rl = ((n, "released") in mv) ? flag(mv[n, "released"]) : 0
    if (rq < 0 || so < 0 || sr < 0 || rl < 0) continue
    print "M\t" id "\t" st "\t" rq "\t" so "\t" sr "\t" rl
    for (k = 1; k <= pc[n]; k++) print "P\t" id "\t" pk[n, k] "\t" pt[n, k] "\t" pv[n, k]
  }
  for (n in oi) {
    id = ov[n, "method_id"]; st = ov[n, "status"]; oid = ov[n, "id"]
    if (!(id in known) || !(st in okstatus)) continue
    if (oid !~ /^[A-Za-z0-9_.:-]+$/) oid = "-"
    fr = (ov[n, "from_at"] == "") ? 0 : epoch(ov[n, "from_at"])
    un = (ov[n, "until_at"] == "") ? 0 : epoch(ov[n, "until_at"])
    if (fr == "" || un == "") continue
    print "O\t" id "\t" st "\t" fr "\t" un "\t" oid
  }
}
