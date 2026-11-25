$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$mgbaSource = Join-Path $root "third_party/mgba"
$cmakeSource = Join-Path $root "native/mgba"
$buildDirectory = Join-Path $root "build/mgba-win-x64"
$outputDirectory = Join-Path $root "artifacts/native/win-x64"

if (-not (Test-Path (Join-Path $mgbaSource "CMakeLists.txt"))) {
    throw "Pinned mGBA source is missing at $mgbaSource. Check out the pinned mGBA revision first."
}
if (-not (Test-Path (Join-Path $cmakeSource "mgba_shim.c"))) {
    throw "PocketGB mGBA shim source is missing."
}

New-Item -ItemType Directory -Force $outputDirectory | Out-Null

$configureArgs = @(
    "-S", $cmakeSource,
    "-B", $buildDirectory,
    "-DCMAKE_BUILD_TYPE=Release",
    "-DLIBMGBA_ONLY=ON",
    "-DM_CORE_GBA=ON",
    "-DM_CORE_GB=ON",
    "-DBUILD_TEST=OFF",
    "-DBUILD_SUITE=OFF",
    "-DBUILD_CINEMA=OFF",
    "-DENABLE_DEBUGGERS=OFF",
    "-DENABLE_SCRIPTING=OFF",
    "-DUSE_PTHREADS=OFF"
)

Write-Host "Configuring pinned mGBA core-only build..." -ForegroundColor Cyan
cmake @configureArgs
if ($LASTEXITCODE -ne 0) { throw "mGBA CMake configuration failed." }

Write-Host "Building pocketgb-mgba.dll..." -ForegroundColor Cyan
cmake --build $buildDirectory --config Release --target pocketgb_mgba --parallel
if ($LASTEXITCODE -ne 0) { throw "mGBA native core build failed." }

$nativeDll = Join-Path $outputDirectory "pocketgb-mgba.dll"
if (-not (Test-Path $nativeDll)) {
    $nativeDll = Join-Path $outputDirectory "Release/pocketgb-mgba.dll"
}
if (-not (Test-Path $nativeDll)) {
    throw "mGBA build completed but pocketgb-mgba.dll was not found in $outputDirectory."
}

$licenseSource = Join-Path $mgbaSource "LICENSE"
$licenseDirectory = Join-Path $outputDirectory "licenses"
New-Item -ItemType Directory -Force $licenseDirectory | Out-Null
if (Test-Path $licenseSource) {
    Copy-Item $licenseSource (Join-Path $licenseDirectory "mGBA-MPL-2.0.txt") -Force
}

$manifest = @'
mGBA upstream revision: 431935616c0e216d650b25b2ea0c0acccd359038
Build mode: core-only (GBA + GB), no desktop frontend
License: Mozilla Public License 2.0
'@
[System.IO.File]::WriteAllText((Join-Path $outputDirectory "mGBA-BUILD.txt"), $manifest, [System.Text.UTF8Encoding]::new($false))

$sizeMiB = [math]::Round((Get-Item $nativeDll).Length / 1MB, 2)
Write-Host "mGBA core built: $nativeDll ($sizeMiB MiB)" -ForegroundColor Green
