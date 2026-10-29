#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Exit 2 is specifically an unavailable AX tree. Never swallow a semantic failure.
binary="${1:-.build/release/Juicebar}"
status=0
"$binary" --verify-quota-accessibility || status=$?
case "$status" in
  0) message='Quota AX semantics passed. VoiceOver interaction remains unverified.' ;;
  2) message='Quota AX tree unavailable. Live accessibility and VoiceOver validation were NOT performed.'
     if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::warning::$message"; fi ;;
  *) exit "$status" ;;
esac
echo "$message"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '\n### Accessibility probe\n\n%s\n' "$message" >> "$GITHUB_STEP_SUMMARY"
fi
