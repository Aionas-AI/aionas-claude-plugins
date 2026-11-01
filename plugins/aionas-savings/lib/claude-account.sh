# aionas-savings helpers for the Claude login file's account fields (AIO‑901).
# Sourced by hooks/plan-report.sh and lib/usage-probe.sh so both send the same
# account and organization the same way. POSIX sh; also bash 3.2 and Git Bash.
# Nothing here touches the network or runs a program found on PATH other than
# awk.

# _pr_uuid VALUE: VALUE when it matches ^[0-9a-fA-F-]{8,64}$, else nothing.
_pr_uuid() {
  case "$1" in '' | *[!0-9a-fA-F-]*) return 0 ;; esac
  if [ ${#1} -ge 8 ] && [ ${#1} -le 64 ]; then printf '%s' "$1"; fi
  return 0
}

# _pr_clean_name: stdin is the raw JSON text of a string (escapes kept). Prints
# the same kind of text with the control characters (C0, DEL, C1) and the bidi
# characters (U+061C, U+200E/F, U+202A-202E, U+2066-2069) removed, whether they
# are written as UTF-8 or as \uXXXX / \n / \t ..., spaces trimmed at both ends
# and cut to 128 characters. Byte-wise (LC_ALL=C), so it is the same in every awk.
_pr_clean_name() {
  LC_ALL=C awk '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i; max = 128 }
    function hex4(h,   i, c, v) {
      if (h !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) return -1
      v = 0
      for (i = 1; i <= 4; i++) { c = index("0123456789abcdef", tolower(substr(h, i, 1))); v = v * 16 + c - 1 }
      return v
    }
    function bad(v) {
      return v < 32 || (v >= 127 && v <= 159) || v == 1564 || v == 8206 || v == 8207 ||
        (v >= 8234 && v <= 8238) || (v >= 8294 && v <= 8297)
    }
    function add(t) { tok[++nt] = t }
    { s = $0; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1); b = ord[c] + 0
        if (c == "\\") {
          d = substr(s, i + 1, 1)
          if (d == "u") {
            v = hex4(substr(s, i + 2, 4))
            if (v < 0) { i += 2; continue }
            if (v >= 55296 && v <= 56319 && substr(s, i + 6, 2) == "\\u") {
              w = hex4(substr(s, i + 8, 4))
              if (w >= 56320 && w <= 57343) { add(substr(s, i, 12)); i += 12; continue }
            }
            if (v >= 55296 && v <= 57343) { i += 6; continue }
            if (!bad(v)) add(substr(s, i, 6))
            i += 6; continue
          }
          if (d == "\"" || d == "\\" || d == "/") add(c d)
          i += 2; continue
        }
        if (b < 32 || b == 127) { i++; continue }
        if (b < 128) { add(c); i++; continue }
        if (b >= 194 && b <= 223) l = 2; else if (b >= 224 && b <= 239) l = 3; else if (b >= 240 && b <= 244) l = 4; else l = 0
        if (l == 0 || i + l - 1 > n) { i++; continue }
        ok = 1
        for (k = 1; k < l; k++) { x = ord[substr(s, i + k, 1)] + 0; if (x < 128 || x > 191) ok = 0 }
        if (!ok) { i++; continue }
        b2 = ord[substr(s, i + 1, 1)] + 0; b3 = ord[substr(s, i + 2, 1)] + 0
        if (b == 194 && b2 <= 159) { i += l; continue }
        if (b == 216 && b2 == 156) { i += l; continue }
        if (b == 226 && b2 == 128 && (b3 == 142 || b3 == 143 || (b3 >= 170 && b3 <= 174))) { i += l; continue }
        if (b == 226 && b2 == 129 && b3 >= 166 && b3 <= 169) { i += l; continue }
        add(substr(s, i, l)); i += l
      }
    }
    END {
      lo = 1; hi = nt
      while (lo <= hi && tok[lo] == " ") lo++
      while (hi >= lo && tok[hi] == " ") hi--
      if (hi - lo + 1 > max) hi = lo + max - 1
      o = ""
      for (k = lo; k <= hi; k++) o = o tok[k]
      printf "%s", o
    }'
}
