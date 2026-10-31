#!/bin/bash
set -e

echo "Building Call Log Manager APK..."

echo ""
echo "Getting dependencies..."
flutter pub get

echo ""
echo "Building APK..."
if [[ -n "${LICENSE_API_BASE_URL:-}" ]]; then
  flutter build apk --release --dart-define="LICENSE_API_BASE_URL=$LICENSE_API_BASE_URL"
else
  flutter build apk --release
fi

echo ""
echo "Build completed!"
echo "APK location: build/app/outputs/flutter-apk/app-release.apk"
echo ""
