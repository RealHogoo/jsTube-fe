param(
    [string]$MediaApiBase = "http://localhost:8084",
    [string]$AdminBaseUrl = "http://localhost:8081",
    [string]$WebhardBaseUrl = "http://localhost:8083",
    [string]$ApkDownloadUrl = "/downloads/jstube-tv.apk",
    [switch]$EnablePwa
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RootDir

$pwaArgs = @()
if (-not $EnablePwa) {
    $pwaArgs += "--pwa-strategy=none"
}

flutter build web `
    @pwaArgs `
    --dart-define="MEDIA_API_BASE=$MediaApiBase" `
    --dart-define="ADMIN_BASE_URL=$AdminBaseUrl" `
    --dart-define="WEBHARD_BASE_URL=$WebhardBaseUrl" `
    --dart-define="APK_DOWNLOAD_URL=$ApkDownloadUrl"

$BootstrapPath = Join-Path $RootDir "build/web/flutter_bootstrap.js"
if (Test-Path $BootstrapPath) {
    $Bootstrap = Get-Content $BootstrapPath -Raw
    $Bootstrap = $Bootstrap -replace "_flutter\.loader\.load\(\s*\);", @"
(async function () {
  if ("serviceWorker" in navigator) {
    try {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(registrations.map((registration) => registration.unregister()));
    } catch (error) {
      console.warn("Failed to unregister stale service workers:", error);
    }
  }
  _flutter.loader.load({
    config: {
      canvasKitBaseUrl: "canvaskit/"
    }
  });
})();
"@
    Set-Content -Path $BootstrapPath -Value $Bootstrap -Encoding UTF8
}

$IndexPath = Join-Path $RootDir "build/web/index.html"
if (Test-Path $IndexPath) {
    $Index = Get-Content $IndexPath -Raw
    $Index = $Index -replace 'flutter_bootstrap\.js(\?v=[^"]*)?', 'flutter_bootstrap.js?v=local-canvaskit'
    Set-Content -Path $IndexPath -Value $Index -Encoding UTF8
}
