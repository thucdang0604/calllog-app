@echo off
echo Building Call Log Manager APK...

echo.
echo Step 1: Cleaning previous builds...
flutter clean

echo.
echo Step 2: Getting dependencies...
flutter pub get

echo.
echo Step 3: Building APK...
flutter build apk --release

echo.
echo Build completed!
echo APK location: build\app\outputs\flutter-apk\app-release.apk
echo.
pause
