@echo off
echo Building Call Log Manager APK...

echo.
echo Getting dependencies...
flutter pub get
if errorlevel 1 exit /b 1

echo.
echo Building APK...
if defined LICENSE_API_BASE_URL (
  flutter build apk --release --dart-define=LICENSE_API_BASE_URL=%LICENSE_API_BASE_URL%
) else (
  flutter build apk --release
)
if errorlevel 1 exit /b 1

echo.
echo Build completed!
echo APK location: build\app\outputs\flutter-apk\app-release.apk
echo.
pause
