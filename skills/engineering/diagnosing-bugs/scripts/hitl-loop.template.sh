#!/usr/bin/env bash
# Human-in-the-loop reproduction template.
# Copy this file, replace the example steps, and run the copy.
# Capture observations only. Never capture credentials or other secrets.

set -euo pipefail

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _
}

capture() {
  local variable="$1"
  local question="$2"
  local answer

  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$variable" '%s' "$answer"
}

# Replace this example with the smallest procedure that reproduces the symptom.
step "Perform the action that triggers the reported behavior."
capture REPRODUCED "Did the exact symptom occur? (y/n)"
capture OBSERVATION "Describe the redacted observable result:"

printf '\n--- Captured ---\n'
printf 'REPRODUCED=%s\n' "$REPRODUCED"
printf 'OBSERVATION=%s\n' "$OBSERVATION"
