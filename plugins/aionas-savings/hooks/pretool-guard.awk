# aionas-savings: classify one Bash command against the guard rules (AIO-860).
#   awk -f pretool-guard.awk rules/guard-store.tsv CMDFILE
# CMDFILE holds the command exactly as JSON-escaped text (one line), so a
# rewrite never decodes or re-encodes it. Prints one line, \037-separated:
#   status  id  kind  new_command  guard_id  program  full
# status: match (a rule rewrites it), bypass (it would, but the command starts
# with AIONAS_FULL=1), skip (a rule matched but it is already quiet), guarded
# (it already starts with AIONAS_GUARD=<id>; id/kind are that rule's), none,
# complex (more than one simple command, or a newline). full is 1 when the
# command starts with AIONAS_FULL=1.
BEGIN { FS = "\t"; nr = 0; S = "\037" }
FILENAME == ARGV[1] {
  if ($1 == "rule" && NF >= 6) { nr++; id[nr] = $2; kind[nr] = $3; re[nr] = $4; skip[nr] = $5; ins[nr] = $6 }
  next
}
{ cmd = cmd (seen++ ? "\n" : "") $0 }
END {
  c = cmd
  sub(/^ +/, "", c)
  pre = ""; gid = ""; bypass = 0
  while (match(c, /^[A-Za-z_][A-Za-z0-9_]*=[^ "'\\]* +/)) {
    w = substr(c, 1, RLENGTH); pre = pre w; c = substr(c, RLENGTH + 1)
    if (w ~ /^AIONAS_FULL=1 +$/) bypass = 1
    if (w ~ /^AIONAS_GUARD=/) { gid = w; sub(/^AIONAS_GUARD=/, "", gid); sub(/ +$/, "", gid) }
  }
  prog = c; sub(/ .*/, "", prog)
  if (seen != 1 || c ~ /[|;&<>`]/ || index(c, "$(") || index(c, "\\n") || index(c, "\\r")) { out("complex", "", ""); exit }
  if (gid != "") {
    for (i = 1; i <= nr; i++) if (id[i] == gid) { out("guarded", i, ""); exit }
    out("guarded", "", ""); exit
  }
  for (i = 1; i <= nr; i++) {
    if (!match(c, re[i]) || RSTART != 1) continue
    head = substr(c, 1, RLENGTH); rest = substr(c, RLENGTH + 1)
    if (rest != "" && substr(rest, 1, 1) != " ") continue
    if (skip[i] != "-" && (rest " ") ~ skip[i]) { out("skip", i, ""); exit }
    nc = "AIONAS_GUARD=" id[i] " " pre head (ins[i] == "-" ? "" : " " ins[i]) rest
    out(bypass ? "bypass" : "match", i, nc)
    exit
  }
  out("none", "", "")
}
function out(st, i, nc) {
  printf "%s%s%s%s%s%s%s%s%s%s%s%s%d\n", st, S, (i == "" ? "" : id[i]), S, (i == "" ? "" : kind[i]), S, nc, S, gid, S, prog, S, bypass
}
