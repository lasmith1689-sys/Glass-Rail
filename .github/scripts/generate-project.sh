#!/bin/bash
# Generates GlassRail.xcodeproj from project.yml (installing XcodeGen when the runner lacks it).
set -euo pipefail
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Installing XcodeGen"
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen >/dev/null
fi
xcodegen --version
xcodegen generate --spec project.yml
