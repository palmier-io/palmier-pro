#!/usr/bin/env bash
set -euo pipefail

doc_path="docs/customizations.md"

if [ ! -f "$doc_path" ]; then
  echo "Missing ${doc_path}" >&2
  exit 1
fi

required_patterns=(
  "Upstream Update Notification Only"
  "OpenAI-Compatible BYOK Agent Runtime"
  "Tool Error Pass-Through"
  "Agent Tool Contract Documentation"
  "Transcript-Driven Cut Guardrails"
  "Caption Readability And Safety"
  "NaturalLanguage Tokenizer Caption Splitting"
  "Volcengine Speech Captions"
  "Palmier UI Feature Policy"
)

for pattern in "${required_patterns[@]}"; do
  if ! grep -q "$pattern" "$doc_path"; then
    echo "${doc_path} is missing required customization entry: ${pattern}" >&2
    exit 1
  fi
done

echo "Customization documentation is present."
