#!/usr/bin/env bash
# Runs every tests/**/*.test.sh (or the files given). Exit 1 if any fails.
set -u
cd "$(dirname "$0")/.." || exit 1
files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  while IFS= read -r f; do files+=("$f"); done < <(find tests -name '*.test.sh' -type f | sort)
fi
failed=0
for f in "${files[@]}"; do
  echo "== $f"
  bash "$f" || failed=1
done
if [ $failed -ne 0 ]; then echo "FAILED"; exit 1; fi
echo "ALL PASSED"
