# aionas-savings (AIO-861): last use of each MCP server and skill, from lines
# of Claude Code's local history (~/.claude/projects/**/*.jsonl) that a grep
# already narrowed to tool calls. Only names and times are read: nothing else
# on a line is kept, printed or sent.
#   usage:  awk -f time.awk -f unused-usage.awk
#   output: kind <TAB> name <TAB> epoch of the last use     (kind: mcp | skill)
# mcp   a call to the tool mcp__<server>__<tool>  -> <server>
# skill a Skill tool call, or a /slash command line (<command-name>/x</command-name>)
function bump(kind, name, t,   k) {
  if (name == "") return
  k = kind "\t" name
  if (!(k in last) || t > last[k]) last[k] = t
}
{
  line = $0
  ts = ""; rest = line
  while (match(rest, /"timestamp":"[^"]*"/)) {
    ts = substr(rest, RSTART + 13, RLENGTH - 14)
    rest = substr(rest, RSTART + RLENGTH)
  }
  if (ts == "") next
  t = epoch(ts)
  if (t == "") next
  t += 0
  rest = line
  while (match(rest, /"name":"mcp__[^"]*"/)) {
    seg = substr(rest, RSTART + 13, RLENGTH - 14)
    rest = substr(rest, RSTART + RLENGTH)
    k = index(seg, "__")
    if (k > 0) seg = substr(seg, 1, k - 1)
    bump("mcp", seg, t)
  }
  rest = line
  while (match(rest, /"name":"Skill","input":\{"skill":"[^"]*"/)) {
    seg = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/^.*"skill":"/, "", seg); sub(/"$/, "", seg)
    bump("skill", seg, t)
  }
  rest = line
  while (match(rest, /<command-name>[^<]*<\/command-name>/)) {
    seg = substr(rest, RSTART + 14, RLENGTH - 29)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/^\//, "", seg)
    bump("skill", seg, t)
  }
}
END { for (k in last) printf "%s\t%d\n", k, last[k] }
