# Local Play Store Release Builder Script
Write-Host "Wiping old caches..." -ForegroundColor Cyan
flutter clean

Write-Host "Fetching dependencies..." -ForegroundColor Cyan
flutter pub get --enforce-lockfile

Write-Host "Adding icons..." -ForegroundColor Cyan
dart run flutter_launcher_icons

Write-Host "Compiling debug version..." -ForegroundColor Green
flutter build apk --debug

Write-Host "Compiling release version..." -ForegroundColor Green
flutter build apk --release

Write-Host "Compiling signed Android App Bundle (.aab) for Google Play..." -ForegroundColor Green
flutter build appbundle --release

Write-Host ""
Write-Host "--------------------------------------------------------" -ForegroundColor Green
Write-Host "Success! Upload this file to the Play Store:" -ForegroundColor White
Write-Host "build\app\outputs\bundle\release\app-release.aab" -ForegroundColor Yellow
Write-Host "--------------------------------------------------------" -ForegroundColor Green
