# aionas-savings: the long-output store's text work (AIO-860). Run with
# LC_ALL=C. The input is one JSON string body exactly as it appears in the
# hook input (escapes kept, one line). Every result is a pure function of
# those bytes, so the same output always gives the same view.
#
#   mode=decode body=FILE        write the decoded bytes to FILE
#   mode=store id=ID head=H tail=T keep=K
#       when there are more than H+T lines: print the JSON-escaped view
#       head(H) + up to K FAILED/Error lines from between + tail(T) + marker
#   mode=cap id=ID rule=R budget=B tokens=N keep=K
#       when the text is over B bytes: print the JSON-escaped view
#       whole lines within B bytes + up to K FAILED/Error lines after + marker
# Prints nothing when there is nothing to cut.
{ s = s (NR > 1 ? "\n" : "") $0 }
END {
  if (mode == "decode") { decode(s); exit }
  n = lines(s)
  if (mode == "store") {
    if (n <= head + tail) exit
    o = ""
    for (i = 1; i <= head; i++) o = o (i > 1 ? "\\n" : "") L[i]
    k = 0
    for (i = head + 1; i <= n - tail && k < keep; i++) if (L[i] ~ /FAILED|Error|ERROR/) { o = o "\\n" L[i]; k++ }
    for (i = n - tail + 1; i <= n; i++) o = o "\\n" L[i]
    o = o "\\n[aionas-store: kept " head "+" tail " of " n " lines, id=" id ". More: aionas-recall " id " [--grep PATTERN]. Full: rerun with AIONAS_FULL=1]"
    printf "%s", o
    exit
  }
  if (mode == "cap") {
    if (length(s) <= budget) exit
    o = ""; used = 0
    for (i = 1; i <= n; i++) {
      if (used + length(L[i]) + 2 > budget) break
      o = o (i > 1 ? "\\n" : "") L[i]; used += length(L[i]) + 2
    }
    kept = i - 1
    if (kept < 1 || kept >= n) exit
    k = 0
    for (; i <= n && k < keep; i++) if (L[i] ~ /FAILED|Error|ERROR/) { o = o "\\n" L[i]; k++ }
    o = o "\\n[aionas-guard: capped " rule " at about " tokens " tokens: kept " kept " of " n " lines, id=" id ". More: aionas-recall " id " [--grep PATTERN]. Full: rerun with AIONAS_FULL=1]"
    printf "%s", o
    exit
  }
}

# lines(x): split the escaped text into L[1..n] at each \n escape (an escaped
# backslash "\\" is set aside first so "\\n" is not taken for a newline). A
# final newline does not start an empty last line.
function lines(x,   m, i) {
  gsub(/\\\\/, "\001", x)
  m = split(x, L, /\\n/)
  if (m > 0 && L[m] == "") m--
  for (i = 1; i <= m; i++) if (index(L[i], "\001")) L[i] = restore(L[i], "\\\\")
  return m
}
function restore(x, with,   o, k) {
  o = ""
  while ((k = index(x, "\001")) > 0) { o = o substr(x, 1, k - 1) with; x = substr(x, k + 1) }
  return o x
}

function hexval(h,   i, c, v) {
  if (length(h) != 4) return -1
  v = 0
  for (i = 1; i <= 4; i++) {
    c = index("0123456789abcdef", tolower(substr(h, i, 1)))
    if (c == 0) return -1
    v = v * 16 + c - 1
  }
  return v
}
function utf8(v) {
  if (v < 128) return sprintf("%c", v)
  if (v < 2048) return sprintf("%c%c", 192 + int(v / 64), 128 + v % 64)
  if (v < 65536) return sprintf("%c%c%c", 224 + int(v / 4096), 128 + int(v / 64) % 64, 128 + v % 64)
  return sprintf("%c%c%c%c", 240 + int(v / 262144), 128 + int(v / 4096) % 64, 128 + int(v / 64) % 64, 128 + v % 64)
}
# decode(x): JSON string escapes -> bytes, written to the file "body".
function decode(x,   m, P, i, c, r, v, w) {
  gsub(/\\\\/, "\001", x)
  m = split(x, P, /\\/)
  printf "%s", restore(P[1], "\\") > body
  for (i = 2; i <= m; i++) {
    c = substr(P[i], 1, 1); r = substr(P[i], 2)
    if (c == "n") c = "\n"
    else if (c == "t") c = "\t"
    else if (c == "r") c = "\r"
    else if (c == "b") c = "\b"
    else if (c == "f") c = "\f"
    else if (c == "u") {
      v = hexval(substr(r, 1, 4)); r = substr(r, 5)
      if (v >= 55296 && v < 56320 && r == "" && i < m && substr(P[i + 1], 1, 1) == "u" && (w = hexval(substr(P[i + 1], 2, 4))) >= 56320 && w < 57344) {
        v = 65536 + (v - 55296) * 1024 + (w - 56320)
        r = r substr(P[i + 1], 6); i++
      }
      c = v < 0 ? "?" : utf8(v)
    }
    printf "%s%s", c, restore(r, "\\") > body
  }
  close(body)
}
