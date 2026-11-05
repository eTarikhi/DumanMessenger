#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path
)

# Read-only Windows/Android setup probe for DumanMessenger G1.
# It does not install software, set environment variables, accept licenses, start devices,
# invoke SDK managers, or change Flutter configuration. It only reads PATH, environment,
# registry-independent common install paths, SDK directories, and version metadata files.

$script:MissingCount = 0
$script:WarningCount = 0

function Write-PreflightResult {
    param(
        [string]$Name,
        [ValidateSet('OK', 'MISSING', 'WARN', 'INFO')]
        [string]$State,
        [string]$Detail
    )

    if ($State -eq 'MISSING') { $script:MissingCount = $script:MissingCount + 1 }
    if ($State -eq 'WARN') { $script:WarningCount = $script:WarningCount + 1 }

    $color = 'Gray'
    if ($State -eq 'OK') { $color = 'Green' }
    if ($State -eq 'MISSING') { $color = 'Red' }
    if ($State -eq 'WARN') { $color = 'Yellow' }

    Write-Host (('[{0,-7}] {1}: {2}' -f $State, $Name, $Detail)) -ForegroundColor $color
}

function Get-CommandPath {
    param([string]$Name)

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    if ($command.Source) { return [string]$command.Source }
    if ($command.Path) { return [string]$command.Path }
    if ($command.Definition) { return [string]$command.Definition }
    return $null
}

function Find-ExistingFile {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }
    return $null
}

function Read-FirstLine {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $line = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
        if ($line) { return ([string]$line).Trim() }
    }
    catch { return $null }
    return $null
}

function Get-DirectoryCount {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue).Count
}

Write-Host 'DumanMessenger G1 Windows preflight (read-only)' -ForegroundColor Cyan
Write-Host ('Project path: {0}' -f $ProjectRoot)
Write-Host ''

if ($env:OS -eq 'Windows_NT') {
    $osVersion = [System.Environment]::OSVersion.Version
    $is64Bit = [System.Environment]::Is64BitOperatingSystem
    if ($osVersion.Build -ge 22000 -and $is64Bit) {
        Write-PreflightResult 'Windows 11 x64' 'OK' ('build {0}' -f $osVersion.Build)
    }
    else {
        Write-PreflightResult 'Windows 11 x64' 'MISSING' ('detected build {0}; Windows 11 x64 requires build 22000 or newer' -f $osVersion.Build)
    }
}
else {
    Write-PreflightResult 'Windows 11 x64' 'MISSING' 'run this probe in Windows PowerShell on the owner Windows 11 machine'
}

$gitPath = Get-CommandPath 'git'
if ($gitPath) {
    Write-PreflightResult 'Git' 'OK' $gitPath
}
else {
    Write-PreflightResult 'Git' 'MISSING' 'install Git for Windows and reopen PowerShell'
}

$flutterPath = Get-CommandPath 'flutter'
$flutterRoot = $null
if ($flutterPath) {
    $flutterBin = Split-Path -Parent $flutterPath
    if ((Split-Path -Leaf $flutterBin) -ieq 'bin') {
        $flutterRoot = Split-Path -Parent $flutterBin
    }
}
if (-not $flutterRoot -and $env:FLUTTER_ROOT -and (Test-Path -LiteralPath $env:FLUTTER_ROOT -PathType Container)) {
    $flutterRoot = $env:FLUTTER_ROOT
}

if ($flutterPath) {
    $flutterVersion = $null
    if ($flutterRoot) {
        $flutterVersion = Read-FirstLine (Join-Path $flutterRoot 'version')
    }
    if ($flutterVersion) {
        Write-PreflightResult 'Flutter on PATH' 'OK' ('{0} ({1})' -f $flutterPath, $flutterVersion)
    }
    else {
        Write-PreflightResult 'Flutter on PATH' 'OK' $flutterPath
        Write-PreflightResult 'Flutter version metadata' 'WARN' 'version file not found; verify with flutter --version --machine'
    }
}
else {
    Write-PreflightResult 'Flutter on PATH' 'MISSING' 'add the selected Flutter SDK bin directory to PATH'
}

$bundledDart = $null
$bundledDartVersion = $null
if ($flutterRoot) {
    $bundledDart = Find-ExistingFile @(
        (Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'),
        (Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.bat')
    )
    $bundledDartVersion = Read-FirstLine (Join-Path $flutterRoot 'bin\cache\dart-sdk\version')
}
if ($bundledDart) {
    $dartDetail = $bundledDart
    if ($bundledDartVersion) { $dartDetail = '{0} (Dart {1})' -f $bundledDart, $bundledDartVersion }
    Write-PreflightResult 'Flutter-bundled Dart SDK' 'OK' $dartDetail
}
else {
    Write-PreflightResult 'Flutter-bundled Dart SDK' 'MISSING' 'Flutter SDK cache is absent or FLUTTER_ROOT could not be resolved; run flutter --version --machine after installing Flutter'
}

$dartPath = Get-CommandPath 'dart'
if ($dartPath) {
    Write-PreflightResult 'Dart CLI on PATH' 'OK' $dartPath
}
elseif ($bundledDart) {
    Write-PreflightResult 'Dart CLI on PATH' 'WARN' 'bundled Dart exists; add Flutter bin to PATH or invoke its dart.exe directly'
}
else {
    Write-PreflightResult 'Dart CLI on PATH' 'MISSING' 'Dart should come from the selected Flutter SDK; do not install an unrelated app SDK'
}

$studioCandidates = @()
if ($env:ProgramFiles) {
    $studioCandidates += (Join-Path $env:ProgramFiles 'Android\Android Studio\bin\studio64.exe')
}
if ($env:LOCALAPPDATA) {
    $studioCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\bin\studio64.exe')
}
$studioCandidates += (Get-CommandPath 'studio64.exe')
$studioExe = Find-ExistingFile $studioCandidates
$studioHome = $null
if ($studioExe) {
    $studioHome = Split-Path -Parent (Split-Path -Parent $studioExe)
    Write-PreflightResult 'Android Studio' 'OK' $studioExe
}

$sdkHomeEnv = $env:ANDROID_HOME
$sdkRootEnv = $env:ANDROID_SDK_ROOT
$sdkRoot = $null
if ($sdkHomeEnv -and $sdkRootEnv) {
    try {
        $homeFull = [System.IO.Path]::GetFullPath($sdkHomeEnv).TrimEnd('\').ToLowerInvariant()
        $rootFull = [System.IO.Path]::GetFullPath($sdkRootEnv).TrimEnd('\').ToLowerInvariant()
        if ($homeFull -ne $rootFull) {
            Write-PreflightResult 'Android SDK environment' 'WARN' 'ANDROID_HOME and ANDROID_SDK_ROOT differ; choose one SDK directory and align them'
        }
    }
    catch {
        Write-PreflightResult 'Android SDK environment' 'WARN' 'one SDK environment variable contains a path that cannot be normalized'
    }
}
if ($sdkHomeEnv -and (Test-Path -LiteralPath $sdkHomeEnv -PathType Container)) {
    $sdkRoot = $sdkHomeEnv
}
elseif ($sdkRootEnv -and (Test-Path -LiteralPath $sdkRootEnv -PathType Container)) {
    $sdkRoot = $sdkRootEnv
    Write-PreflightResult 'ANDROID_HOME' 'WARN' 'ANDROID_HOME is unset; ANDROID_SDK_ROOT is present. Prefer ANDROID_HOME for new setup.'
}
elseif ($env:LOCALAPPDATA) {
    $defaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path -LiteralPath $defaultSdk -PathType Container) {
        $sdkRoot = $defaultSdk
        Write-PreflightResult 'ANDROID_HOME' 'WARN' 'SDK found at the common location but ANDROID_HOME is not configured'
    }
}

if ($sdkRoot) {
    Write-PreflightResult 'Android SDK root' 'OK' $sdkRoot
}
else {
    Write-PreflightResult 'Android SDK root' 'MISSING' 'install the SDK in Android Studio or command-line tools and set ANDROID_HOME'
}

$sdkManagerPath = $null
$sdkManagerCommand = Get-CommandPath 'sdkmanager.bat'
if (-not $sdkManagerCommand) { $sdkManagerCommand = Get-CommandPath 'sdkmanager' }
$adbPath = $null
$emulatorPath = $null
$hasAndroidPlatform = $false
$hasBuildTools = $false
$hasAcceptedLicenseMarker = $false
if ($sdkRoot) {
    $sdkManagerDir = Join-Path $sdkRoot 'cmdline-tools'
    if (Test-Path -LiteralPath $sdkManagerDir -PathType Container) {
        $sdkManager = Get-ChildItem -LiteralPath $sdkManagerDir -Filter 'sdkmanager.bat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sdkManager) { $sdkManagerPath = $sdkManager.FullName }
    }

    $adbPath = Find-ExistingFile @((Join-Path $sdkRoot 'platform-tools\adb.exe'))
    $emulatorPath = Find-ExistingFile @((Join-Path $sdkRoot 'emulator\emulator.exe'))
    $hasAndroidPlatform = (Get-DirectoryCount (Join-Path $sdkRoot 'platforms')) -gt 0
    $hasBuildTools = (Get-DirectoryCount (Join-Path $sdkRoot 'build-tools')) -gt 0
    $licensePath = Join-Path $sdkRoot 'licenses\android-sdk-license'
    if (Test-Path -LiteralPath $licensePath -PathType Leaf) {
        $hasAcceptedLicenseMarker = ((Get-Item -LiteralPath $licensePath).Length -gt 0)
    }
}

if ($sdkManagerPath) {
    if ($sdkManagerCommand) {
        Write-PreflightResult 'Android command-line tools' 'OK' $sdkManagerCommand
    }
    else {
        Write-PreflightResult 'Android command-line tools' 'WARN' ('installed at {0}; add its bin directory to PATH for direct sdkmanager commands' -f $sdkManagerPath)
    }
}
elseif ($sdkManagerCommand) {
    Write-PreflightResult 'Android command-line tools' 'OK' $sdkManagerCommand
}
elseif ($studioExe) {
    Write-PreflightResult 'Android command-line tools' 'MISSING' 'Android Studio exists; install Android SDK Command-line Tools from SDK Manager'
}
else {
    Write-PreflightResult 'Android Studio or command-line tools' 'MISSING' 'install free Android Studio or the official Android command-line tools'
}

$adbCommand = Get-CommandPath 'adb'
if ($adbPath -and $adbCommand) {
    Write-PreflightResult 'Android platform-tools / adb' 'OK' $adbCommand
}
elseif ($adbPath) {
    Write-PreflightResult 'Android platform-tools / adb' 'WARN' ('installed at {0}; add the platform-tools directory to PATH' -f $adbPath)
}
elseif ($adbCommand) {
    Write-PreflightResult 'Android platform-tools / adb' 'WARN' ('found on PATH outside the detected SDK root: {0}' -f $adbCommand)
}
else {
    Write-PreflightResult 'Android platform-tools / adb' 'MISSING' 'install Android SDK Platform-Tools and add its platform-tools directory to PATH'
}

if ($emulatorPath) {
    Write-PreflightResult 'Android Emulator' 'OK' $emulatorPath
}
else {
    Write-PreflightResult 'Android Emulator' 'MISSING' 'install Android Emulator in SDK Manager'
}

if ($hasAndroidPlatform) {
    Write-PreflightResult 'Android SDK platform' 'OK' 'at least one platform is installed; verify compileSdk after Flutter creates the project'
}
else {
    Write-PreflightResult 'Android SDK platform' 'WARN' 'no SDK platform found; install the compileSdk required by the generated app'
}
if ($hasBuildTools) {
    Write-PreflightResult 'Android build-tools' 'OK' 'at least one version is installed; verify the project-required version'
}
else {
    Write-PreflightResult 'Android build-tools' 'WARN' 'no build-tools version found; install the version required by the generated app'
}
if ($hasAcceptedLicenseMarker) {
    Write-PreflightResult 'Android license marker' 'OK' 'license marker exists; flutter doctor --android-licenses is still the authoritative check'
}
else {
    Write-PreflightResult 'Android license marker' 'WARN' 'licenses may be unaccepted; run flutter doctor --android-licenses interactively'
}

$javaPath = Get-CommandPath 'java'
$javacPath = Get-CommandPath 'javac'
$jdkHome = $null
if ($env:JAVA_HOME) {
    $javaFromHome = Join-Path $env:JAVA_HOME 'bin\java.exe'
    $javacFromHome = Join-Path $env:JAVA_HOME 'bin\javac.exe'
    if ((Test-Path -LiteralPath $javaFromHome -PathType Leaf) -and (Test-Path -LiteralPath $javacFromHome -PathType Leaf)) {
        $jdkHome = $env:JAVA_HOME
    }
}
if (-not $jdkHome -and $studioHome) {
    $studioJbr = Join-Path $studioHome 'jbr'
    $studioJava = Join-Path $studioJbr 'bin\java.exe'
    $studioJavac = Join-Path $studioJbr 'bin\javac.exe'
    if ((Test-Path -LiteralPath $studioJava -PathType Leaf) -and (Test-Path -LiteralPath $studioJavac -PathType Leaf)) {
        $jdkHome = $studioJbr
    }
}
if (-not $jdkHome -and $javaPath -and $javacPath) {
    $javaBin = Split-Path -Parent $javaPath
    $javacBin = Split-Path -Parent $javacPath
    if ($javaBin -ieq $javacBin) { $jdkHome = Split-Path -Parent $javaBin }
}
if ($jdkHome) {
    $javaReleaseLine = $null
    $javaReleaseFile = Join-Path $jdkHome 'release'
    if (Test-Path -LiteralPath $javaReleaseFile -PathType Leaf) {
        $javaReleaseLine = Select-String -LiteralPath $javaReleaseFile -Pattern '^JAVA_VERSION=' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($javaReleaseLine) {
        Write-PreflightResult 'JDK (java + javac)' 'OK' ('{0}; {1}' -f $jdkHome, $javaReleaseLine.Line.Trim())
    }
    else {
        Write-PreflightResult 'JDK (java + javac)' 'OK' $jdkHome
    }
    Write-PreflightResult 'AGP/JDK compatibility' 'INFO' 'not guessed here; verify Flutter doctor and the generated AGP/Gradle requirements before building'
}
else {
    Write-PreflightResult 'JDK (java + javac)' 'MISSING' 'use the Android Studio bundled JBR if suitable, or install a JDK required by the generated AGP/Gradle versions'
}
if ($env:JAVA_HOME) {
    Write-PreflightResult 'JAVA_HOME' 'INFO' $env:JAVA_HOME
}
else {
    Write-PreflightResult 'JAVA_HOME' 'WARN' 'unset; Android Studio JBR can still be selected by Flutter, verify with flutter doctor -v'
}
if ($javaPath) {
    Write-PreflightResult 'Java command on PATH' 'OK' $javaPath
}
else {
    Write-PreflightResult 'Java command on PATH' 'WARN' 'not found; Flutter may use Android Studio JBR, confirm with flutter doctor -v'
}

$avdRoot = $null
if ($env:USERPROFILE) { $avdRoot = Join-Path $env:USERPROFILE '.android\avd' }
$avdFiles = @()
if ($avdRoot -and (Test-Path -LiteralPath $avdRoot -PathType Container)) {
    $avdFiles = @(Get-ChildItem -LiteralPath $avdRoot -Filter '*.ini' -File -ErrorAction SilentlyContinue)
}
if ($avdFiles.Count -gt 0) {
    Write-PreflightResult 'Android Virtual Device' 'OK' ('{0} AVD definition(s) found' -f $avdFiles.Count)
}
else {
    Write-PreflightResult 'Android Virtual Device' 'WARN' 'create an emulator in Android Studio Device Manager; no emulator is started by this script'
}

$projectAndroid = Join-Path $ProjectRoot 'android'
if (Test-Path -LiteralPath $projectAndroid -PathType Container) {
    $wrapperPath = Join-Path $projectAndroid 'gradle\wrapper\gradle-wrapper.properties'
    if (Test-Path -LiteralPath $wrapperPath -PathType Leaf) {
        $wrapperLine = Select-String -LiteralPath $wrapperPath -Pattern '^distributionUrl=' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wrapperLine) {
            Write-PreflightResult 'Project Gradle wrapper' 'INFO' $wrapperLine.Line.Trim()
        }
    }
    $gradleFiles = @(Get-ChildItem -LiteralPath $projectAndroid -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(settings|build)\.gradle(\.kts)?$' })
    if ($gradleFiles.Count -gt 0) {
        $pluginLines = Select-String -Path $gradleFiles.FullName -Pattern 'com\.android\.application|com\.android\.tools\.build:gradle' -ErrorAction SilentlyContinue
        foreach ($line in $pluginLines) {
            Write-PreflightResult 'Project Android Gradle Plugin declaration' 'INFO' $line.Line.Trim()
        }
    }
    Write-PreflightResult 'Project compatibility check' 'WARN' 'compare the selected AGP and Gradle wrapper with their official compatibility requirements and flutter doctor -v'
}
else {
    Write-PreflightResult 'Project Gradle/AGP compatibility' 'INFO' 'no Android project yet; use Flutter-generated Gradle files and verify their compatibility before the first build'
}

Write-Host ''
$preflightExitCode = 0
if ($script:MissingCount -eq 0) {
    Write-Host ('Preflight found no missing required components ({0} warning(s)).' -f $script:WarningCount) -ForegroundColor Green
}
else {
    $preflightExitCode = 1
    Write-Host ('Preflight found {0} missing required component(s) and {1} warning(s).' -f $script:MissingCount, $script:WarningCount) -ForegroundColor Red
    Write-Host 'This is a read-only report. Install/configure missing items, reopen PowerShell, then rerun.' -ForegroundColor Yellow
}

[pscustomobject]@{
    ExitCode = $preflightExitCode
    MissingCount = $script:MissingCount
    WarningCount = $script:WarningCount
}
