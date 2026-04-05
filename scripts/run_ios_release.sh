#!/usr/bin/env bash
# Optional: chmod +x scripts/run_ios_release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f pubspec.yaml ]]; then
  echo "error: pubspec.yaml not found in $ROOT"
  exit 1
fi

flutter pub get
flutter build ios --release

cat <<'EOF'

Next steps:
  open ios/Runner.xcworkspace
  Pick "Any iOS Device (arm64)" or your plugged-in iPhone, select your signing team,
  then Product → Run for a device build, or Product → Archive for App Store / ad hoc.

Reminders: device may need Developer Mode (Settings → Privacy & Security) and USB trust.
EOF
