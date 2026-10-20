# aionas-savings: flatten one JSON document into lines, POSIX awk only
# (BWK awk on macOS, mawk on Debian/Ubuntu, gawk in Git Bash on Windows).
#
#   path <TAB> type <TAB> value
#
# path   keys and array indexes joined with ".", e.g. methods.0.method_id
#        (the root container has the empty path).
# type   o (object), a (array), s (string), n (number), b (true/false), z (null)
# value  strings: the raw JSON text between the quotes (escapes kept, so one
#        value is always one line; aionas_json_unescape decodes it);
#        numbers and booleans: the literal; containers and null: empty.
#
# Exit 2 and print nothing useful on invalid JSON, a raw newline inside a
# string, or nesting deeper than 64.
BEGIN { s = ""; err = 0 }
{ s = s $0 "\n" }
END {
  n = length(s); i = 1
  skipws()
  value("", 0)
  skipws()
  if (err || i <= n) { print "aionas-json: invalid JSON" > "/dev/stderr"; exit 2 }
  printf "%s", out
}
function emit(p, t, v) { out = out p "\t" t "\t" v "\n" }
function join(p, k) { return p == "" ? k : p "." k }
function skipws(   c) {
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
    else break
  }
}
function str(   start, c, v) {
  if (substr(s, i, 1) != "\"") { err = 1; return "" }
  i++; start = i
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == "\"") {
      v = substr(s, start, i - start); i++
      if (index(v, "\n") || index(v, "\t")) { err = 1; return "" }
      return v
    }
    i++
  }
  err = 1; return ""
}
function value(p, d,   c, k, idx, t) {
  if (err) return
  if (d > 64) { err = 1; return }
  skipws(); c = substr(s, i, 1)
  if (c == "{") {
    emit(p, "o", ""); i++; skipws()
    if (substr(s, i, 1) == "}") { i++; return }
    while (!err) {
      skipws(); k = str(); if (err) return
      skipws(); if (substr(s, i, 1) != ":") { err = 1; return }
      i++; value(join(p, k), d + 1); if (err) return
      skipws(); c = substr(s, i, 1)
      if (c == ",") { i++; continue }
      if (c == "}") { i++; return }
      err = 1; return
    }
    return
  }
  if (c == "[") {
    emit(p, "a", ""); i++; skipws()
    if (substr(s, i, 1) == "]") { i++; return }
    idx = 0
    while (!err) {
      value(join(p, idx), d + 1); if (err) return
      idx++
      skipws(); c = substr(s, i, 1)
      if (c == ",") { i++; continue }
      if (c == "]") { i++; return }
      err = 1; return
    }
    return
  }
  if (c == "\"") { t = str(); if (!err) emit(p, "s", t); return }
  if (substr(s, i, 4) == "true") { emit(p, "b", "true"); i += 4; return }
  if (substr(s, i, 5) == "false") { emit(p, "b", "false"); i += 5; return }
  if (substr(s, i, 4) == "null") { emit(p, "z", ""); i += 4; return }
  if (match(substr(s, i, 64), /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) {
    emit(p, "n", substr(s, i, RLENGTH)); i += RLENGTH; return
  }
  err = 1
}
