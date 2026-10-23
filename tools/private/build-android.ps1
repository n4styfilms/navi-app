param(
    [Parameter(Mandatory=$true)][string]$SdkPath,
    [Parameter(Mandatory=$true)][string]$JavaHome,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$PythonPath = 'python',
    [switch]$ResourcesPrepared
)
$ErrorActionPreference='Stop'
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(Test-Path -LiteralPath (Join-Path $OutputDirectory 'Navi-Basis.apk')) { throw 'Output already contains an APK' }
foreach($taskRequired in @((Join-Path $JavaHome 'bin/java.exe'), (Join-Path $SdkPath 'ndk/28.2.13676358/build/cmake/android.toolchain.cmake'))) {
    if(!(Test-Path -LiteralPath $taskRequired)) { throw "Missing dependency: $taskRequired" }
}
if(!$ResourcesPrepared) { throw 'First prepare the upstream resources with configure.sh in a complete build environment, or use the free Linux workflow.' }
if(!(Test-Path -LiteralPath (Join-Path $taskRoot 'data/drules_proto_driving_light.bin'))) { throw 'Generated map resources missing' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$taskOutput=(Resolve-Path -LiteralPath $OutputDirectory).Path
$taskOldJava=$env:JAVA_HOME; $taskOldSdk=$env:ANDROID_HOME
try {
    $env:JAVA_HOME=$JavaHome; $env:ANDROID_HOME=$SdkPath
    Push-Location $taskRoot
    try {
        $taskCommit=git rev-parse HEAD
        if($LASTEXITCODE -ne 0) { throw 'Cannot read source commit' }
        @{source_commit=$taskCommit} | ConvertTo-Json | Set-Content -LiteralPath 'android/sdk/src/main/assets/private-build.json' -Encoding utf8NoBOM
        Push-Location android
        try { & ./gradlew.bat --no-daemon -Parm64 -Pnjobs=4 assembleWebBeta; if($LASTEXITCODE -ne 0) { throw 'Gradle build failed' } } finally { Pop-Location }
        $taskApks=@(Get-ChildItem -LiteralPath 'android/app/build/outputs/apk/web/beta' -Filter '*.apk')
        if($taskApks.Count -ne 1) { throw 'Expected exactly one APK' }
        $taskArtifact=Join-Path $taskOutput 'Navi-Basis.apk'
        Copy-Item -LiteralPath $taskApks[0].FullName -Destination $taskArtifact
        & $PythonPath tools/private/verify_artifacts.py --report (Join-Path $taskOutput 'apk-report.json') apk $taskArtifact --aapt2 (Join-Path $SdkPath 'build-tools/36.0.0/aapt2.exe') --apksigner (Join-Path $SdkPath 'build-tools/36.0.0/apksigner.bat')
        if($LASTEXITCODE -ne 0) { throw 'APK verification failed' }
    } finally { Pop-Location }
} finally { $env:JAVA_HOME=$taskOldJava; $env:ANDROID_HOME=$taskOldSdk }
