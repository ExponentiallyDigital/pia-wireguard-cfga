# Builder script
Write-Host "Wiping old caches..." -ForegroundColor Cyan
flutter clean

Write-Host "Fetching dependencies..." -ForegroundColor Cyan
flutter pub get --enforce-lockfile

Write-Host "Adding icons..." -ForegroundColor Cyan
dart run flutter_launcher_icons

Write-Host "Running tests..." -ForegroundColor Cyan
flutter test --coverage


Write-Host "Compiling debug version..." -ForegroundColor Green
flutter build apk --debug

Write-Host "Compiling release version..." -ForegroundColor Green
flutter build apk --release

Write-Host "Compiling signed Android App Bundle (.aab) for Google Play..." -ForegroundColor Green
flutter build appbundle --release

Write-Host ""
Write-Host "-------------------------------------------------------------------------------" -ForegroundColor DarkMagenta
Write-Host "Play Store:   " -ForegroundColor White -NoNewline
Write-Host ".\build\app\outputs\" -ForegroundColor Green -NoNewline
Write-Host "bundle\release\" -ForegroundColor Cyan -NoNewline
Write-Host "pia_wireguard_cfga-release.aab" -ForegroundColor Yellow
Write-Host "Side loading: " -ForegroundColor White -NoNewline
Write-Host ".\build\app\outputs\" -ForegroundColor Green -NoNewline
Write-Host "flutter-apk\" -ForegroundColor Cyan -NoNewline
Write-Host "app-release.apk" -ForegroundColor Yellow
Write-Host "Debug:        " -ForegroundColor White -NoNewline
Write-Host ".\build\app\outputs\" -ForegroundColor Green -NoNewline
Write-Host "flutter-apk\" -ForegroundColor Cyan -NoNewline
Write-Host "app-debug.apk" -ForegroundColor Yellow
Write-Host "-------------------------------------------------------------------------------" -ForegroundColor DarkMagenta
Write-Host ""
