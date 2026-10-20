# aionas-savings JSON helpers (no jq: awk only). Sourced via aionas.sh.

# aionas_json_flatten [FILE]: JSON (FILE or stdin) -> "path<TAB>type<TAB>value"
# lines (see json.awk). Exit 2 on invalid JSON.
aionas_json_flatten() {
  if [ $# -gt 0 ]; then
    awk -f "$AIONAS_LIB/json.awk" "$1"
  else
    awk -f "$AIONAS_LIB/json.awk"
  fi
}

# aionas_json_get PATH: from flattened lines on stdin, print the raw value at
# PATH (exact match). Exit 1 when PATH is absent.
aionas_json_get() {
  awk -F '\t' -v p="$1" '$1 == p { print $3; f = 1; exit } END { exit f ? 0 : 1 }'
}

# aionas_json_type PATH: like aionas_json_get, but prints the type letter.
aionas_json_type() {
  awk -F '\t' -v p="$1" '$1 == p { print $2; f = 1; exit } END { exit f ? 0 : 1 }'
}

# aionas_json_unescape: decode the JSON string escapes of each stdin line
# (\" \\ \/ \b \f \n \r \t; \uXXXX below 0x80 becomes the character, others
# stay as written).
aionas_json_unescape() {
  awk '
    function hex(h,   i, c, v) {
      v = 0
      for (i = 1; i <= 4; i++) {
        c = index("0123456789abcdef", tolower(substr(h, i, 1)))
        if (c == 0) return -1
        v = v * 16 + c - 1
      }
      return v
    }
    {
      s = $0; o = ""
      while ((k = index(s, "\\")) > 0) {
        o = o substr(s, 1, k - 1); c = substr(s, k + 1, 1); s = substr(s, k + 2)
        if (c == "n") o = o "\n"
        else if (c == "t") o = o "\t"
        else if (c == "r") o = o "\r"
        else if (c == "b") o = o "\b"
        else if (c == "f") o = o "\f"
        else if (c == "u") {
          v = hex(substr(s, 1, 4))
          if (v >= 32 && v < 127) { o = o sprintf("%c", v); s = substr(s, 5) }
          else if (v >= 0 && v < 32) { o = o sprintf("%c", v); s = substr(s, 5) }
          else o = o "\\u"
        }
        else o = o c
      }
      print o s
    }'
}

# aionas_json_escape STRING: print STRING as a JSON string literal (quotes
# included). Control characters become escapes. (A trailing "." is added
# before awk and dropped after, so a final newline is kept.)
aionas_json_escape() {
  printf '%s.' "$1" | awk '
    BEGIN { for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
            ctl["\t"] = "\\t"; ctl["\r"] = "\\r"; ctl["\b"] = "\\b"; ctl["\f"] = "\\f" }
    {
      line = (NR > 1 ? "\\n" : "")
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") line = line "\\\\"
        else if (c == "\"") line = line "\\\""
        else if (c in ctl) line = line ctl[c]
        else line = line c
      }
      o = o line
    }
    END { printf "\"%s\"", substr(o, 1, length(o) - 1) }'
}
