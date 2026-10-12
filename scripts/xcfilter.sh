#!/bin/bash
# Trims xcodebuild output to the lines that matter (errors, warnings, test
# results, final status) and preserves xcodebuild's exit code through the pipe.
# Set VERBOSE=1 to see everything.
set -o pipefail

if [ -n "$VERBOSE" ]; then
  cat
  exit 0
fi

status=0
while IFS= read -r line; do
  case "$line" in
    *"error:"*|*"warning:"*|*"** BUILD"*|*"** TEST"*|"Test Suite"*|"Test Case"*"failed"*|*"Executed "*|*"Testing failed"*|*"Failing tests"*)
      echo "$line" ;;
  esac
  case "$line" in
    *"** BUILD FAILED **"*|*"** TEST FAILED **"*) status=1 ;;
  esac
done
exit $status
