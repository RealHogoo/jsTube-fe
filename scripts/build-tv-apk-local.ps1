$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$OutputDir = Join-Path $RootDir "build\downloads"
$ApkSource = Join-Path $RootDir "build\app\outputs\flutter-apk\app-release.apk"
$ApkTarget = Join-Path $OutputDir "jstube-tv.apk"

Set-Location $RootDir

flutter build apk --release `
    --dart-define=KARAOKE_TV=true `
    --dart-define=MEDIA_API_BASE=http://localhost:8084 `
    --dart-define=ADMIN_BASE_URL=http://localhost:8081 `
    --dart-define=WEBHARD_BASE_URL=http://localhost:8083

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Copy-Item -Force -LiteralPath $ApkSource -Destination $ApkTarget

Write-Host "TV APK built: $ApkTarget"
