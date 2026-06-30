#!/usr/bin/env bash
set -euo pipefail

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/post-merge .githooks/post-rewrite
chmod +x scripts/sync-agent-tool-docs.swift scripts/check-customizations-doc.sh
echo "Installed PalmierPro git hooks from .githooks"
