#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts"
cp "$root/Justfile" "$tmp/Justfile"
export COUNT="$tmp/count"
echo 0 > "$COUNT"

# A fetch that fails the first $FAIL_TIMES calls then succeeds, so this proves
# the prepare-parent target retries instead of failing on the first try.
cat > "$tmp/scripts/fetch-runtime-parent.sh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$COUNT"
[ "$count" -le "${FAIL_TIMES:-0}" ] && exit 1
exit 0
EOF

run_parent() { ( cd "$tmp" && PARENT_RETRY_DELAY=0 just prepare-parent ); }

# Fails twice, succeeds on the third attempt: the release proceeds.
export FAIL_TIMES=2
run_parent || { echo 'prepare-parent should have succeeded after retries' >&2; exit 1; }
[ "$(cat "$COUNT")" -eq 3 ] || { echo "expected 3 attempts, got $(cat "$COUNT")" >&2; exit 1; }

# Always fails: the release fails after exactly three attempts, not one.
echo 0 > "$COUNT"
export FAIL_TIMES=99
if run_parent; then echo 'prepare-parent should have failed' >&2; exit 1; fi
[ "$(cat "$COUNT")" -eq 3 ] || { echo "expected 3 attempts, got $(cat "$COUNT")" >&2; exit 1; }

echo 'prepare-parent retry OK'
