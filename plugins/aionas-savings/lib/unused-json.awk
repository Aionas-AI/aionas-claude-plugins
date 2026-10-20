# aionas-savings (AIO-861): read or surgically edit one place in a big JSON
# file (Claude Code's ~/.claude.json or settings.json), POSIX awk only.
# Everything outside the edited spot stays byte for byte as it was.
#
# Input is given through the environment (no escape processing, so raw JSON
# text such as C:\\Users\\me survives):
#   AU_OP    members | items | add-item | del-item | set-str
#   AU_PATH  object keys from the root, TAB separated, each as raw JSON text
#            (the text between the quotes). The last key names the member the
#            operation works on; "" means the root object (members only).
#   AU_VAL   raw JSON text (no quotes) for add-item, del-item and set-str
#
# members   print "key<TAB>type<TAB>value" for each member of the object at
#           AU_PATH (type: s o a n b z; value only for strings, raw text)
# items     print the raw text of each string in the array at AU_PATH
# add-item  make AU_VAL an item of the array at AU_PATH (created, with its
#           parents, when missing; a null value becomes the array)
# del-item  remove AU_VAL from the array at AU_PATH
# set-str   set the member at AU_PATH to the string AU_VAL (created when missing)
#
# Edits print the whole new file and exit 0, or print nothing and exit 10 when
# nothing needed to change. Exit 2: invalid JSON. Exit 4: the file has
# something else (not an object / array) where the edit would go; it is left
# alone. Reads print nothing for a missing path.
BEGIN {
  op = ENVIRON["AU_OP"]; val = ENVIRON["AU_VAL"]
  np = (ENVIRON["AU_PATH"] == "") ? 0 : split(ENVIRON["AU_PATH"], P, "\t")
  nl = 0; have_edit = 0
}
{ L[++nl] = $0 }
END {
  if (nl == 0) { L[1] = "{}"; nl = 1 }
  cl = 1; cc = 1
  skipws()
  if (cur() != "{") bad(2)
  if (np == 0) {
    if (op != "members") bad(4)
    final(0)
  } else {
    walkobj(0)
  }
  skipws()
  if (cl <= nl) bad(2)
  if (op == "members" || op == "items") exit 0
  if (!have_edit) exit 10
  emit_edit()
  exit 0
}

function bad(code) { exit code }
function cur() { return substr(L[cl], cc, 1) }
function skipws(   m) {
  while (cl <= nl) {
    if (match(substr(L[cl], cc), /^[ \t\r]*/)) cc += RLENGTH
    if (cc > length(L[cl])) { cl++; cc = 1; continue }
    return
  }
}
# parse_string: cursor on the opening quote; returns the raw text, leaves the
# cursor after the closing quote.
function parse_string(   raw, rest, a, b, m) {
  if (cur() != "\"") bad(2)
  cc++; raw = ""
  for (;;) {
    rest = substr(L[cl], cc)
    a = index(rest, "\""); b = index(rest, "\\")
    if (a == 0 && b == 0) bad(2)
    if (b > 0 && (a == 0 || b < a)) {
      if (b == length(rest)) bad(2)
      raw = raw substr(rest, 1, b + 1); cc += b + 1
      continue
    }
    raw = raw substr(rest, 1, a - 1); cc += a
    return raw
  }
}
# skip_value: cursor on a value; leaves the cursor after it.
function skip_value(   c, depth, rest, m, ch) {
  skipws(); c = cur()
  if (c == "") bad(2)
  if (c == "\"") { parse_string(); return }
  if (c == "{" || c == "[") {
    depth = 1; cc++
    while (depth > 0) {
      if (cl > nl) bad(2)
      rest = substr(L[cl], cc)
      m = match(rest, /[]["{}[]/)
      if (!m) { cl++; cc = 1; continue }
      ch = substr(rest, m, 1)
      if (ch == "\"") { cc += m - 1; parse_string() }
      else if (ch == "{" || ch == "[") { depth++; cc += m }
      else { depth--; cc += m }
    }
    return
  }
  if (!match(substr(L[cl], cc), /^[^]}, \t\r]+/)) bad(2)
  cc += RLENGTH
}
function vtype(   c) {
  c = cur()
  if (c == "\"") return "s"
  if (c == "{") return "o"
  if (c == "[") return "a"
  if (substr(L[cl], cc, 4) == "null") return "z"
  if (substr(L[cl], cc, 4) == "true" || substr(L[cl], cc, 5) == "false") return "b"
  return "n"
}

# walkobj: cursor on the "{" of the object whose path prefix P[1..level] was
# matched. Looks for member P[level+1].
function walkobj(level,   key, found, n, lastL, lastC, oL, oC, c, mk) {
  oL = cl; oC = cc; cc++
  n = 0; found = 0; lastL = oL; lastC = oC + 1
  for (;;) {
    skipws(); c = cur()
    if (c == "}") break
    if (c != "\"") bad(2)
    key = parse_string()
    skipws(); if (cur() != ":") bad(2)
    cc++; skipws()
    if (!found && key == P[level + 1]) {
      found = 1
      if (level + 1 == np) final(level + 1)
      else if (cur() == "{") walkobj(level + 1)
      else if (is_edit() && vtype() == "z") null_to_path(level + 1)
      else bad(is_edit() ? 4 : 0)
    } else skip_value()
    n++; lastL = cl; lastC = cc
    skipws(); c = cur()
    if (c == ",") { cc++; continue }
    if (c == "}") break
    bad(2)
  }
  cc++
  if (!found && creates()) {
    edit_set(lastL, lastC, lastL, lastC, (n > 0 ? "," : "") "\"" P[level + 1] "\":" bval(level + 1))
  }
}
function is_edit() { return op == "add-item" || op == "del-item" || op == "set-str" }
function creates() { return op == "add-item" || op == "set-str" }
# bval: the text for a new member P[j] whose value is the leaf (j == np) or an
# object holding the next key.
function bval(j) {
  if (j == np) return leaf()
  return "{\"" P[j + 1] "\":" bval(j + 1) "}"
}
function leaf() { return (op == "add-item") ? "[\"" val "\"]" : "\"" val "\"" }
# A null where an object is needed on the way to the edit: replace it.
function null_to_path(j,   sl, sc) {
  if (op == "del-item") { skip_value(); return }
  sl = cl; sc = cc; skip_value()
  edit_set(sl, sc, cl, cc, "{\"" P[j + 1] "\":" bval(j + 1) "}")
}

# final: cursor on the value of the member the operation is about.
function final(lv,   sl, sc, t, c, n, i, key, raw, el, ec, eEl, eEc, rawv, pL, pC) {
  skipws(); sl = cl; sc = cc; t = vtype()
  if (op == "members") {
    if (t != "o") { skip_value(); return }
    cc++
    for (;;) {
      skipws(); c = cur()
      if (c == "}") { cc++; return }
      if (c == ",") { cc++; continue }
      if (c != "\"") bad(2)
      key = parse_string(); skipws(); if (cur() != ":") bad(2)
      cc++; skipws(); t = vtype()
      if (t == "s") { raw = parse_string(); print key "\t" t "\t" raw }
      else { skip_value(); print key "\t" t "\t" }
    }
  }
  if (op == "set-str") {
    skip_value()
    if (t == "s" && substr(L[sl], sc + 1, length(val) + 1) == val "\"") return
    edit_set(sl, sc, cl, cc, "\"" val "\"")
    return
  }
  # items / add-item / del-item work on an array
  if (t == "z" && op == "add-item") { skip_value(); edit_set(sl, sc, cl, cc, "[\"" val "\"]"); return }
  if (t != "a") {
    skip_value()
    if (op == "items") return
    if (op == "del-item" && t == "z") return
    bad(4)
  }
  cc++; n = 0
  pL = cl; pC = cc          # just after "["
  for (;;) {
    skipws(); c = cur()
    if (c == "]") { cc++; break }
    if (c == ",") { cc++; continue }
    n++; sL[n] = cl; sC[n] = cc
    if (cur() == "\"") { rawv = parse_string(); R[n] = rawv; isstr[n] = 1 }
    else { skip_value(); R[n] = ""; isstr[n] = 0 }
    eL[n] = cl; eC[n] = cc
  }
  if (op == "items") {
    for (i = 1; i <= n; i++) if (isstr[i]) print R[i]
    return
  }
  if (op == "add-item") {
    for (i = 1; i <= n; i++) if (isstr[i] && R[i] == val) return
    if (n == 0) edit_set(pL, pC, pL, pC, "\"" val "\"")
    else edit_set(eL[n], eC[n], eL[n], eC[n], ",\"" val "\"")
    return
  }
  # del-item: the first match
  for (i = 1; i <= n; i++) if (isstr[i] && R[i] == val) break
  if (i > n) return
  if (n == 1) edit_set(sL[1], sC[1], eL[1], eC[1], "")
  else if (i < n) edit_set(sL[i], sC[i], sL[i + 1], sC[i + 1], "")
  else edit_set(eL[i - 1], eC[i - 1], eL[i], eC[i], "")
}

function edit_set(l1, c1, l2, c2, text) {
  if (have_edit) return
  have_edit = 1; E1l = l1; E1c = c1; E2l = l2; E2c = c2; Etext = text
}
function emit_edit(   i, joined) {
  for (i = 1; i < E1l; i++) print L[i]
  joined = substr(L[E1l], 1, E1c - 1) Etext substr(L[E2l], E2c)
  print joined
  for (i = E2l + 1; i <= nl; i++) print L[i]
}
