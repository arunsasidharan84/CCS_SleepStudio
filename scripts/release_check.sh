#!/usr/bin/env bash
# Pre-release checks from docs/RELEASE_SOP.md, then (optionally) commit + push.
#
#   bash scripts/release_check.sh          # run all checks, write release_check.log
#   bash scripts/release_check.sh --push   # run checks; if all pass, commit and push
#
# The log (release_check.log in the repo root) lets Claude read the results.
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LOG="$ROOT/release_check.log"
VERSION=$(grep '^version:' frontend/pubspec.yaml | head -n1 | sed -E 's/version:[[:space:]]*([0-9.]+).*/\1/')
: > "$LOG"
fail=0

step() {
  local name="$1"; shift
  echo "=== $name ===" | tee -a "$LOG"
  ( "$@" ) >> "$LOG" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then
    echo "PASS: $name" | tee -a "$LOG"
  else
    echo "FAIL ($rc): $name" | tee -a "$LOG"
    fail=1
  fi
}

echo "CCS Sleep Studio v$VERSION — release checks ($(date))" | tee -a "$LOG"
step "bridge: cargo test"         bash -c "cd bridge && cargo test"
step "analyseNidra: cargo test"   bash -c "cd analyseNidra && cargo test"
step "frontend: flutter pub get"  bash -c "cd frontend && flutter pub get"
step "frontend: flutter analyze"  bash -c "cd frontend && flutter analyze"
step "frontend: flutter test"     bash -c "cd frontend && flutter test"

if [ $fail -ne 0 ]; then
  echo "Some checks failed — see release_check.log. Nothing was committed." | tee -a "$LOG"
  exit 1
fi
echo "All checks passed." | tee -a "$LOG"

if [ "${1:-}" = "--push" ]; then
  echo "=== git status ===" | tee -a "$LOG"
  git status --short | grep -v 'release_check.log\|tmp/claude_src.tgz' | tee -a "$LOG"
  read -r -p "Commit ALL changes above as v$VERSION and push? [y/N] " ok
  if [ "$ok" != "y" ] && [ "$ok" != "Y" ]; then
    echo "Not committed." | tee -a "$LOG"; exit 0
  fi
  git add -A
  git reset -q -- release_check.log tmp/claude_src.tgz 2>/dev/null
  git commit -F - <<MSG >> "$LOG" 2>&1
feat(viewer): keep markers after filtering, window-only display filters, spectrogram toggle (off by default), selection durations, right-click hide channel, filter button; bump to v$VERSION [build desktop] [build release]

Release notes: docs/release_notes/v$VERSION.md
MSG
  git push >> "$LOG" 2>&1 && echo "Pushed — CI will build and publish v$VERSION." | tee -a "$LOG" \
    || { echo "Push failed — see release_check.log." | tee -a "$LOG"; exit 1; }
fi
