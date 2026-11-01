# aionas-savings: parse the text of Claude Code's /usage result (AIO-892).
# Input: the result text, one line per line. -v now=EPOCH (for the year).
# Run with lib/time.awk first:  awk -v now=E -f time.awk -f usage-probe.awk
# Output, only when the first "Current week (all models): " line is a plain
# "N% used" with N from 0 to 100, one line of four fields separated by \037:
#   percent, zone, wall1, wall2
# percent is N as a short number. zone and wall1/wall2 are empty unless the
# reset text is exactly "<Mon> <D> at <H>[:MM]<am|pm> (<zone>)" in English,
# with a valid date; wall1/wall2 are that wall-clock time as seconds since the
# epoch AS IF it were UTC, for the clock's year and the next one. The shell
# turns a wall time into a real instant with the zone's own offset. No other
# line is ever read: a "(Fable)" or session line is ignored.
# Anything else prints nothing and exits 1. This file never prints the text.
BEGIN { found = 0; bad = 0; label = "Current week (all models): " }
found { next }
substr($0, 1, length(label)) != label { next }
{
  found = 1
  rest = substr($0, length(label) + 1)
  if (!match(rest, /^[0-9][0-9]?[0-9]?(\.[0-9]+)?% used/)) { bad = 1; next }
  num = substr(rest, 1, RLENGTH - 6)
  x = num + 0
  if (x < 0 || x > 100) { bad = 1; next }
  pct = sprintf("%.4f", x); sub(/0+$/, "", pct); sub(/\.$/, "", pct)
  zone = ""; w1 = ""; w2 = ""
  i = index(rest, "resets ")
  if (i > 0) reset(substr(rest, i + 7))
}
END {
  if (!found || bad) exit 1
  printf "%s\037%s\037%s\037%s\n", pct, zone, w1, w2
}
function reset(txt,   n, p, mon, d, tm, ap, hm, h, mi, z, m, pos, y0, yy, k, e, w) {
  if (!match(txt, /^[A-Z][a-z][a-z] [0-9][0-9]? at [0-9][0-9]?(:[0-9][0-9])?(am|pm|AM|PM) \([^)]+\)$/)) return
  n = split(txt, p, " ")
  if (n != 5) return
  mon = p[1]; d = p[2] + 0; tm = p[4]
  if (substr(p[5], length(p[5])) != ")") return
  z = substr(p[5], 2, length(p[5]) - 2)
  if (z !~ /^[A-Za-z_]+(\/[A-Za-z0-9_+-]+)?(\/[A-Za-z0-9_+-]+)?$/) return
  pos = index("JanFebMarAprMayJunJulAugSepOctNovDec", mon)
  if (pos == 0 || (pos - 1) % 3 != 0) return
  m = (pos - 1) / 3 + 1
  ap = tolower(substr(tm, length(tm) - 1))
  tm = substr(tm, 1, length(tm) - 2)
  split(tm, hm, ":")
  h = hm[1] + 0; mi = (hm[2] == "" ? 0 : hm[2] + 0)
  if (h < 1 || h > 12 || mi < 0 || mi > 59 || d < 1 || d > 31) return
  h = h % 12 + (ap == "pm" ? 12 : 0)
  y0 = substr(day(now + 0), 1, 4) + 0
  for (k = 0; k < 2; k++) {
    yy = y0 + k
    e = civil_days(yy, m, d) * 86400
    if (day(e) != sprintf("%04d-%02d-%02d", yy, m, d)) continue
    w = e + h * 3600 + mi * 60
    if (k == 0) w1 = sprintf("%d", w); else w2 = sprintf("%d", w)
  }
  if (w1 == "" && w2 == "") return
  zone = z
}
