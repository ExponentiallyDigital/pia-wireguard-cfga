# Local Play Store Release Builder Script
Write-Host "Wiping old caches..." -ForegroundColor Cyan
flutter clean

Write-Host "Fetching dependencies..." -ForegroundColor Cyan
flutter pub get --enforce-lockfile

Write-Host "Adding icons..." -ForegroundColor Cyan
dart run flutter_launcher_icons

Write-Host "Compiling signed Android App Bundle (.aab) for Google Play..." -ForegroundColor Green
flutter build appbundle --release

Write-Host "Compiling release for local use..." -ForegroundColor Green
flutter build --release

Write-Host "--------------------------------------------------------" -ForegroundColor Green
Write-Host "Success! Upload the file located at:" -ForegroundColor White
Write-Host "build\app\outputs\bundle\release\app-release.aab" -ForegroundColor Yellow
Write-Host "--------------------------------------------------------" -ForegroundColor Green
