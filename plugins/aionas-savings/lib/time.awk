# aionas-savings time helpers, POSIX awk.
#   -v mode=day -v t=EPOCH      -> YYYY-MM-DD (UTC)
#   -v mode=epoch -v iso=STRING -> epoch seconds of an RFC 3339 time
#                                  (Z or +hh:mm/-hh:mm; fractions ignored),
#                                  exit 2 when it does not parse
# With no mode it only defines day() and epoch() for another -f program.
BEGIN {
  if (mode == "day") { print day(t + 0); exit 0 }
  if (mode == "epoch") { e = epoch(iso); if (e == "") exit 2; print e; exit 0 }
}
function civil_days(y, m, d,   era, yoe, doy, doe) {
  y -= (m <= 2)
  era = int((y >= 0 ? y : y - 399) / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function day(e,   z, era, doe, yoe, y, doy, mp, d, m) {
  z = int(e / 86400) + 719468
  era = int((z >= 0 ? z : z - 146096) / 146097)
  doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = mp + (mp < 10 ? 3 : -9)
  y += (m <= 2)
  return sprintf("%04d-%02d-%02d", y, m, d)
}
function epoch(s,   y, mo, d, h, mi, se, rest, off, sign) {
  if (!match(s, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][Tt ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return ""
  y = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
  h = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60) return ""
  rest = substr(s, 20)
  if (match(rest, /^\.[0-9]+/)) rest = substr(rest, RLENGTH + 1)
  off = 0
  if (rest == "Z" || rest == "z") off = 0
  else if (match(rest, /^[-+][0-9][0-9]:[0-9][0-9]$/)) {
    sign = substr(rest, 1, 1) == "-" ? -1 : 1
    off = sign * ((substr(rest, 2, 2) + 0) * 3600 + (substr(rest, 5, 2) + 0) * 60)
  } else return ""
  return sprintf("%d", civil_days(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - off)
}
