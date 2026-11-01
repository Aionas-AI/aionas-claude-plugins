usage-2.1.311.json: reconstructed from the issue text, not a live capture.
The issue quotes the two "Current week" lines of a 2.1.311 /usage result; the
session line and the surrounding JSON keys here are filled in to look like
Claude Code's -p --output-format json shape and are UNVERIFIED. The parser reads
only top-level local_command and result, and only the "Current week (all
models)" line of result.

stub-claude.sh: stands in for the claude binary in tests/unit/usage-probe.test.sh.
It never contacts anything; it logs its argv, cwd and AIONAS_* environment to
$STUB_LOG/run.<n>/ and prints $STUB_OUTPUT.
