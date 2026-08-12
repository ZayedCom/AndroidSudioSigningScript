# Signing Script — Android Studio release builder (APK + AAB)
# Created by Zaid K. Al Qassar (ZayedCom)
# https://github.com/ZayedCom
# Double-click signing-script.bat, or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File ".\signing-script.ps1"

param(
    [string]$ProjectRoot,
    [string]$OutDir,
    [string]$AppName,
    [switch]$Reconfigure
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KeystorePropsFile = Join-Path $ScriptDir "keystore.properties"
$ProjectPropsFile = Join-Path $ScriptDir "project.properties"
$ProjectsDir = Join-Path $ScriptDir "projects"
$LastProjectFile = Join-Path $ProjectsDir "last-id.txt"

$script:ProjectId = $null
$script:ProjectRoot = $null
$script:OutDir = $null
$script:AppName = $null
$script:StoreFile = $null
$script:StorePassword = $null
$script:KeyAlias = $null
$script:KeyPassword = $null
$script:VersionBackups = @{}
$script:TempInitScript = $null
$script:TempCredsFile = $null
$script:BannerWidth = 66
$script:ProgressOpen = $false

function Show-Banner {
    Write-Host ""
    $art = @'
  ____  _             _               ____            _       _
 / ___|(_) __ _ _ __ (_)_ __   __ _  / ___|  ___ _ __(_)_ __ | |_
 \___ \| |/ _` | '_ \| | '_ \ / _` | \___ \ / __| '__| | '_ \| __|
  ___) | | (_| | | | | | | | | (_| |  ___) | (__| |  | | |_) | |_
 |____/|_|\__, |_| |_|_|_| |_|\__, | |____/ \___|_|  |_| .__/ \__|
          |___/               |___/                    |_|
'@
    $lines = @(
        @{ Text = "Android Studio - Release APK + AAB"; Color = "DarkCyan" }
        @{ Text = "Created by Zaid K. Al Qassar - ZayedCom"; Color = "DarkGray" }
        @{ Text = "https://github.com/ZayedCom"; Color = "DarkGray" }
    )
    $width = ($art -split "`r?`n" | Measure-Object -Property Length -Maximum).Maximum
    foreach ($line in $lines) {
        if ($line.Text.Length -gt $width) { $width = $line.Text.Length }
    }
    $script:BannerWidth = $width

    Write-Host $art -ForegroundColor Cyan
    foreach ($line in $lines) {
        $pad = [Math]::Max(0, [int][Math]::Floor(($width - $line.Text.Length) / 2))
        Write-Host ((" " * $pad) + $line.Text) -ForegroundColor $line.Color
    }
    Write-Host ""
}

function Get-RuleWidth {
    param([string[]]$FitTo)
    $w = $script:BannerWidth
    if (-not $w -or $w -lt 1) { $w = 66 }
    foreach ($s in @($FitTo)) {
        if ($s -and $s.Length -gt $w) { $w = $s.Length }
    }
    return $w
}

function Show-Separator {
    param([string[]]$FitTo)
    Write-Host (("-" * (Get-RuleWidth -FitTo $FitTo))) -ForegroundColor DarkGray
}

function Format-DottedProgress([int]$Percent, [int]$Width) {
    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $labelLen = 0
    for ($p = 10; $p -le 100; $p += 10) { $labelLen += ("$p%").Length }
    $minWidth = $labelLen + 10
    if ($Width -lt $minWidth) { $Width = $minWidth }

    $dotsTotal = $Width - $labelLen
    $base = [int][Math]::Floor($dotsTotal / 10)
    $rem = $dotsTotal % 10
    $gaps = New-Object int[] 10
    for ($i = 0; $i -lt 10; $i++) {
        $n = $base
        if ($i -ge (10 - $rem)) { $n++ }
        $gaps[$i] = $n
    }

    $shown = New-Object System.Text.StringBuilder
    $done = [int][Math]::Floor($Percent / 10)
    for ($i = 0; $i -lt $done; $i++) {
        [void]$shown.Append("." * $gaps[$i])
        [void]$shown.Append((($i + 1) * 10).ToString() + "%")
    }
    if ($Percent -lt 100) {
        $frac = ($Percent % 10) / 10.0
        $partial = [int][Math]::Floor($gaps[$done] * $frac)
        if ($partial -gt 0) { [void]$shown.Append("." * $partial) }
    }
    return $shown.ToString()
}

function Write-DottedProgress([int]$Percent) {
    $width = Get-RuleWidth
    $bar = Format-DottedProgress $Percent $width
    $clear = [Math]::Max(0, $width - $bar.Length)
    Write-Host ("`r" + $bar + (" " * $clear)) -NoNewline -ForegroundColor Cyan
    $script:ProgressOpen = $true
}

function Complete-DottedProgress {
    if ($script:ProgressOpen) {
        Write-Host ""
        $script:ProgressOpen = $false
    }
}

function Receive-GradleOutputLine($obj) {
    if ($null -eq $obj) { return }
    $line = "$obj"
    if ($obj -is [System.Management.Automation.ErrorRecord]) {
        $line = $obj.ToString()
    }

    $rich = [regex]::Match($line, '<[=->]+\s+(\d{1,3})%')
    if ($rich.Success) {
        Write-DottedProgress ([int]$rich.Groups[1].Value)
        return
    }

    $trimmed = $line.Trim()
    $isDotBar = ($trimmed -match '%') -and ($trimmed -match '^[\.0-9%\s]+$')
    if ($isDotBar) {
        $max = 0
        foreach ($m in [regex]::Matches($trimmed, '(\d{1,3})%')) {
            $v = [int]$m.Groups[1].Value
            if ($v -le 100 -and $v -gt $max) { $max = $v }
        }
        Write-DottedProgress $max
        return
    }

    if ($line -match '(?i)Downloading\s+') {
        Complete-DottedProgress
        Write-Host $line
        return
    }

    if ($line -match 'BUILD SUCCESSFUL') {
        Write-DottedProgress 100
        Complete-DottedProgress
        Write-Host $line -ForegroundColor Cyan
        return
    }

    if ($line -match 'BUILD FAILED') {
        Complete-DottedProgress
        Write-Host $line -ForegroundColor Red
        return
    }

    Complete-DottedProgress
    Write-Host $line
}

function Invoke-GradleWithProgress {
    param(
        [string]$Gradle,
        [string[]]$Tasks,
        [string]$InitScript
    )

    $gradleArgs = @($Tasks) + @("--init-script", $InitScript, "--no-daemon")
    $script:ProgressOpen = $false
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Gradle @gradleArgs 2>&1 | ForEach-Object { Receive-GradleOutputLine $_ }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
        Complete-DottedProgress
    }
    return $code
}

function ConvertFrom-SecureStringPlain([Security.SecureString]$secure) {
    if ($null -eq $secure) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-PlainPath([string]$prompt, [string]$default = "") {
    $suffix = if ($default) { " [$default]" } else { "" }
    $value = Read-Host ($prompt + $suffix)
    if ($null -eq $value) { $value = "" }
    $value = $value.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($value)) { return $default }
    if ($value.StartsWith("~")) {
        $value = $value -replace "^~", $env:USERPROFILE
    }
    return $value
}

function Read-PlainText([string]$prompt, [string]$default = "") {
    $suffix = if ($default) { " [$default]" } else { "" }
    $value = Read-Host ($prompt + $suffix)
    if ($null -eq $value) { $value = "" }
    $value = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $default }
    return $value
}

function Read-RequiredPassword([string]$prompt) {
    while ($true) {
        $sec = Read-Host $prompt -AsSecureString
        $plain = ConvertFrom-SecureStringPlain $sec
        if (-not [string]::IsNullOrEmpty($plain)) { return $plain }
        Write-Host "  Password cannot be empty." -ForegroundColor Yellow
    }
}

function Read-OptionalPassword([string]$prompt) {
    $sec = Read-Host $prompt -AsSecureString
    return ConvertFrom-SecureStringPlain $sec
}

function Read-PropsFile([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    foreach ($line in ($raw -split "`r?`n")) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $i = $line.IndexOf("=")
        if ($i -lt 1) { continue }
        $map[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1)
    }
    return $map
}

function Write-PropsFile([string]$path, [hashtable]$map, [string[]]$order, [string[]]$header) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($h in $header) { [void]$lines.Add($h) }
    foreach ($k in $order) {
        $val = ""
        if ($map.ContainsKey($k) -and $null -ne $map[$k]) { $val = [string]$map[$k] }
        [void]$lines.Add("$k=$val")
    }
    $text = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Get-SafeFileName([string]$name) {
    $out = $name
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
        $out = $out.Replace([string]$c, "")
    }
    return $out.Trim()
}

function Resolve-ExistingPath([string]$path, [string]$baseDir) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    $path = $path.Trim().Trim('"')
    if ($path.StartsWith("~")) {
        $path = $path -replace "^~", $env:USERPROFILE
    }
    if (-not [IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $baseDir $path
    }
    if (-not (Test-Path $path)) { return $null }
    return (Resolve-Path $path).Path
}

function Get-SettingsFile([string]$root) {
    foreach ($name in @("settings.gradle.kts", "settings.gradle")) {
        $p = Join-Path $root $name
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-GradleWrapper([string]$root) {
    $bat = Join-Path $root "gradlew.bat"
    if (Test-Path $bat) { return $bat }
    $sh = Join-Path $root "gradlew"
    if (Test-Path $sh) { return $sh }
    return $null
}

function Test-AndroidStudioProject([string]$root) {
    if (-not (Test-Path $root -PathType Container)) {
        throw "Not a folder: $root"
    }
    if (-not (Get-SettingsFile $root)) {
        throw "No settings.gradle / settings.gradle.kts in: $root"
    }
    if (-not (Get-GradleWrapper $root)) {
        throw "No gradlew / gradlew.bat in: $root"
    }
}

function Get-DefaultAppName([string]$root) {
    $settings = Get-SettingsFile $root
    if ($settings) {
        $text = Get-Content $settings -Raw -Encoding UTF8
        if ($text -match 'rootProject\.name\s*=\s*["'']([^"'']+)["'']') {
            return $Matches[1]
        }
    }
    return (Split-Path $root -Leaf)
}

function Get-IncludedGradleModules([string]$settingsText) {
    $names = New-Object System.Collections.Generic.List[string]
    $cleaned = [regex]::Replace($settingsText, '/\*[\s\S]*?\*/', "")
    $cleaned = [regex]::Replace($cleaned, '(?m)//.*$', "")
    $cleaned = [regex]::Replace($cleaned, 'includeBuild\s*\([^)]*\)', "")

    $pattern = '(?i)(?<![\w])include\s*\(([\s\S]*?)\)|(?i)(?<![\w])include\s+([^\r\n]+)'
    foreach ($m in [regex]::Matches($cleaned, $pattern)) {
        $chunk = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        foreach ($q in [regex]::Matches($chunk, '[''"]([^''"]+)[''"]')) {
            $n = $q.Groups[1].Value.Trim()
            if ($n.StartsWith(":")) { $n = $n.Substring(1) }
            $n = $n.Trim().TrimStart(":")
            if (-not [string]::IsNullOrWhiteSpace($n) -and -not $names.Contains($n)) {
                [void]$names.Add($n)
            }
        }
    }
    return $names
}

function Get-ModuleGradleFile([string]$root, [string]$relDir) {
    $kts = Join-Path $relDir "build.gradle.kts"
    $groovy = Join-Path $relDir "build.gradle"
    if (Test-Path (Join-Path $root $kts)) { return $kts }
    if (Test-Path (Join-Path $root $groovy)) { return $groovy }
    return $null
}

function Test-AndroidApplicationModule([string]$root, [string]$relDir, [string]$gradleFile) {
    $full = Join-Path $root $gradleFile
    if (-not (Test-Path $full)) { return $false }
    $text = Get-Content $full -Raw -Encoding UTF8
    $hasAppPlugin = $text -match 'com\.android\.application' -or $text -match 'android\.application'
    $hasAppId = $text -match 'applicationId'
    $hasLibPlugin = $text -match 'com\.android\.library' -or $text -match 'android\.library'
    if ($hasAppPlugin) { return $true }
    if ($hasAppId -and -not $hasLibPlugin) { return $true }
    return $false
}

function Test-HasAndroidManifest([string]$root, [string]$relDir) {
    $manifest = Join-Path $root (Join-Path $relDir "src\main\AndroidManifest.xml")
    return (Test-Path $manifest)
}

function Get-ModuleFolderName([string]$gradleName) {
    $last = ($gradleName -split ":")[-1]
    $key = $last.ToLowerInvariant()
    $map = @{
        "app"         = "Phone"
        "phone"       = "Phone"
        "mobile"      = "Phone"
        "handheld"    = "Phone"
        "wear"        = "Wear"
        "wearos"      = "Wear"
        "wearable"    = "Wear"
        "sync"        = "Sync"
        "tv"          = "TV"
        "television"  = "TV"
        "androidtv"   = "TV"
        "auto"        = "Auto"
        "automotive"  = "Auto"
        "car"         = "Auto"
        "desktop"     = "Desktop"
        "androiddesktop" = "Desktop"
    }
    if ($map.ContainsKey($key)) { return $map[$key] }
    return (Get-Culture).TextInfo.ToTitleCase($last)
}

function Get-ModuleLabel([string]$appName, [string]$gradleName, [string]$folder) {
    $last = ($gradleName -split ":")[-1]
    if ($last -match '^(?i)(app|phone|mobile|handheld)$') {
        return $appName
    }
    return "$appName $folder"
}

function Find-AppModules([string]$root, [string]$appName) {
    $settings = Get-SettingsFile $root
    if (-not $settings) { throw "settings.gradle not found in $root" }
    $text = Get-Content $settings -Raw -Encoding UTF8
    $included = @(Get-IncludedGradleModules $text)

    $commonApp = @(
        "app", "phone", "mobile", "handheld", "wear", "wearos", "wearable",
        "sync", "tv", "television", "androidtv", "auto", "automotive", "car",
        "desktop"
    )

    if ($included.Count -eq 0) {
        $rootGradle = Get-ModuleGradleFile $root "."
        if ($rootGradle -and (Test-AndroidApplicationModule $root "." $rootGradle)) {
            $folder = "Phone"
            return ,[pscustomobject]@{
                Gradle      = ""
                Path        = "."
                Label       = $appName
                Folder      = $folder
                GradleFile  = $rootGradle
                IsApp       = $true
                HasManifest = Test-HasAndroidManifest $root "."
                IsCommon    = $true
            }
        }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($gradleName in $included) {
        $relDir = $gradleName.Replace(":", "\")
        $gradleFile = Get-ModuleGradleFile $root $relDir
        if (-not $gradleFile) { continue }

        $isApp = Test-AndroidApplicationModule $root $relDir $gradleFile
        $hasManifest = Test-HasAndroidManifest $root $relDir
        $last = ($gradleName -split ":")[-1]
        $isCommon = $commonApp -contains $last.ToLowerInvariant()

        $folder = Get-ModuleFolderName $gradleName
        $label = Get-ModuleLabel $appName $gradleName $folder
        $entry = [pscustomobject]@{
            Gradle     = $gradleName
            Path       = $relDir
            Label      = $label
            Folder     = $folder
            GradleFile = $gradleFile
            IsApp      = $isApp
            HasManifest = $hasManifest
            IsCommon   = $isCommon
        }
        [void]$candidates.Add($entry)
    }

    $apps = @($candidates | Where-Object { $_.IsApp })
    if ($apps.Count -eq 0) {
        $apps = @($candidates | Where-Object { $_.HasManifest -and $_.IsCommon })
    }
    if ($apps.Count -eq 0) {
        $apps = @($candidates | Where-Object { $_.HasManifest })
    }

    if ($apps.Count -eq 0) {
        $listed = if ($included.Count) { $included -join ", " } else { "(none)" }
        throw @"
No Android application modules found in:
  $root

Included Gradle projects: $listed

The project needs at least one module with com.android.application
(or applicationId) in its build.gradle / build.gradle.kts.
"@
    }

    $sorted = @($apps | Sort-Object Folder, Gradle)
    return ,$sorted
}

function Get-NormalizedPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    try {
        return [IO.Path]::GetFullPath($path.Trim().Trim('"')).TrimEnd("\", "/")
    }
    catch {
        return $path.Trim().TrimEnd("\", "/")
    }
}

function Get-LastProjectId {
    if (-not (Test-Path $LastProjectFile)) { return $null }
    $id = [System.IO.File]::ReadAllText($LastProjectFile, [System.Text.UTF8Encoding]::new($false)).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return $id
}

function Save-LastProjectId([string]$id) {
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    New-Item -ItemType Directory -Force -Path $ProjectsDir | Out-Null
    [System.IO.File]::WriteAllText($LastProjectFile, $id.Trim() + "`r`n", [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-SavedProject($map, [string]$filePath) {
    $id = ""
    if ($map.ContainsKey("id")) { $id = $map["id"].Trim() }
    if (-not $id -and $filePath) { $id = [IO.Path]::GetFileNameWithoutExtension($filePath) }
    $get = {
        param($key)
        if ($map.ContainsKey($key) -and $null -ne $map[$key]) { return ([string]$map[$key]).Trim() }
        return ""
    }
    return [pscustomobject]@{
        Id            = $id
        AppName       = & $get "appName"
        ProjectRoot   = & $get "projectRoot"
        OutDir        = & $get "outDir"
        StoreFile     = & $get "storeFile"
        StorePassword = if ($map.ContainsKey("storePassword") -and $null -ne $map["storePassword"]) { [string]$map["storePassword"] } else { "" }
        KeyAlias      = & $get "keyAlias"
        KeyPassword   = if ($map.ContainsKey("keyPassword") -and $null -ne $map["keyPassword"]) { [string]$map["keyPassword"] } else { "" }
        FilePath      = $filePath
    }
}

function Get-SavedProjects {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $ProjectsDir)) { return @() }
    foreach ($file in Get-ChildItem -Path $ProjectsDir -Filter "*.properties" -File -ErrorAction SilentlyContinue) {
        $map = Read-PropsFile $file.FullName
        if (-not $map.ContainsKey("appName") -or [string]::IsNullOrWhiteSpace($map["appName"])) { continue }
        if (-not $map.ContainsKey("projectRoot") -or [string]::IsNullOrWhiteSpace($map["projectRoot"])) { continue }
        [void]$list.Add((ConvertTo-SavedProject $map $file.FullName))
    }
    $sorted = @($list | Sort-Object AppName, ProjectRoot)
    return ,$sorted
}

function Find-SavedProjectByRoot([string]$root) {
    $norm = Get-NormalizedPath $root
    if (-not $norm) { return $null }
    foreach ($p in @(Get-SavedProjects)) {
        if ((Get-NormalizedPath $p.ProjectRoot) -eq $norm) { return $p }
    }
    return $null
}

function Test-SavedProjectReady($p) {
    if ($null -eq $p) { return $false }
    if ([string]::IsNullOrWhiteSpace($p.AppName)) { return $false }
    if ([string]::IsNullOrWhiteSpace($p.ProjectRoot)) { return $false }
    if ([string]::IsNullOrWhiteSpace($p.OutDir)) { return $false }
    if ([string]::IsNullOrWhiteSpace($p.StoreFile)) { return $false }
    if ([string]::IsNullOrWhiteSpace($p.StorePassword)) { return $false }
    if ([string]::IsNullOrWhiteSpace($p.KeyAlias)) { return $false }
    if ([string]::IsNullOrWhiteSpace($p.KeyPassword)) { return $false }
    try { Test-AndroidStudioProject $p.ProjectRoot } catch { return $false }
    $store = Resolve-ExistingPath $p.StoreFile $ScriptDir
    return [bool]$store
}

function Use-SavedProject($p) {
    $script:ProjectId = $p.Id
    $script:AppName = $p.AppName
    $script:ProjectRoot = $p.ProjectRoot
    $script:OutDir = $p.OutDir
    $script:StoreFile = $p.StoreFile
    $script:StorePassword = $p.StorePassword.Trim()
    $script:KeyAlias = $p.KeyAlias
    $script:KeyPassword = $p.KeyPassword.Trim()
    Save-LastProjectId $script:ProjectId
    Save-ActiveSnapshot
}

function Clear-CurrentProject([switch]$KeepCli) {
    $keepRoot = $null
    $keepOut = $null
    $keepName = $null
    if ($KeepCli) {
        $keepRoot = $script:ProjectRoot
        $keepOut = $script:OutDir
        $keepName = $script:AppName
    }
    $script:ProjectId = $null
    $script:ProjectRoot = $keepRoot
    $script:OutDir = $keepOut
    $script:AppName = $keepName
    $script:StoreFile = $null
    $script:StorePassword = $null
    $script:KeyAlias = $null
    $script:KeyPassword = $null
}

function Save-ActiveSnapshot {
    if ($script:ProjectRoot -and $script:OutDir -and $script:AppName) {
        Write-PropsFile $ProjectPropsFile @{
            projectRoot = $script:ProjectRoot
            outDir      = $script:OutDir
            appName     = $script:AppName
        } @("projectRoot", "outDir", "appName") @(
            "# Active project snapshot for Signing Script."
            "# This file is machine-specific. Do not commit it."
        )
    }
    if ($script:StoreFile -and $script:StorePassword -and $script:KeyAlias -and $script:KeyPassword) {
        Write-PropsFile $KeystorePropsFile @{
            storeFile     = $script:StoreFile
            storePassword = $script:StorePassword
            keyAlias      = $script:KeyAlias
            keyPassword   = $script:KeyPassword
        } @("storeFile", "storePassword", "keyAlias", "keyPassword") @(
            "# Active signing snapshot for Signing Script."
            "# This file contains secrets. Do not commit it."
        )
    }
}

function Save-CurrentProject {
    if ([string]::IsNullOrWhiteSpace($script:ProjectId)) {
        $existing = Find-SavedProjectByRoot $script:ProjectRoot
        if ($existing) {
            $script:ProjectId = $existing.Id
        }
        else {
            $script:ProjectId = [guid]::NewGuid().ToString("N")
        }
    }
    New-Item -ItemType Directory -Force -Path $ProjectsDir | Out-Null
    $path = Join-Path $ProjectsDir "$($script:ProjectId).properties"
    Write-PropsFile $path @{
        id            = $script:ProjectId
        appName       = $script:AppName
        projectRoot   = $script:ProjectRoot
        outDir        = $script:OutDir
        storeFile     = $script:StoreFile
        storePassword = $script:StorePassword
        keyAlias      = $script:KeyAlias
        keyPassword   = $script:KeyPassword
    } @("id", "appName", "projectRoot", "outDir", "storeFile", "storePassword", "keyAlias", "keyPassword") @(
        "# Saved Signing Script project profile."
        "# Contains keystore paths and passwords. Do not commit this folder."
    )
    Save-LastProjectId $script:ProjectId
    Save-ActiveSnapshot
    return $path
}

function Remove-SavedProject($p) {
    if ($p.FilePath -and (Test-Path $p.FilePath)) {
        Remove-Item $p.FilePath -Force
    }
    if ($script:ProjectId -eq $p.Id) {
        Clear-CurrentProject
    }
}

function Import-LegacyProjectIfNeeded {
    $existing = @(Get-SavedProjects)
    if ($existing.Count -gt 0) { return }
    if (-not (Test-Path $ProjectPropsFile) -or -not (Test-Path $KeystorePropsFile)) { return }
    $proj = Read-PropsFile $ProjectPropsFile
    $ks = Read-PropsFile $KeystorePropsFile
    foreach ($k in @("projectRoot", "outDir", "appName")) {
        if (-not $proj.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($proj[$k])) { return }
    }
    foreach ($k in @("storeFile", "storePassword", "keyAlias", "keyPassword")) {
        if (-not $ks.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($ks[$k])) { return }
    }
    $script:ProjectId = [guid]::NewGuid().ToString("N")
    $script:AppName = $proj["appName"].Trim()
    $script:ProjectRoot = $proj["projectRoot"].Trim()
    $script:OutDir = $proj["outDir"].Trim()
    $script:StoreFile = $ks["storeFile"].Trim()
    $script:StorePassword = $ks["storePassword"].Trim()
    $script:KeyAlias = $ks["keyAlias"].Trim()
    $script:KeyPassword = $ks["keyPassword"].Trim()
    [void](Save-CurrentProject)
}

function Get-ActiveKeystore {
    if ([string]::IsNullOrWhiteSpace($script:StoreFile) -or
        [string]::IsNullOrWhiteSpace($script:StorePassword) -or
        [string]::IsNullOrWhiteSpace($script:KeyAlias) -or
        [string]::IsNullOrWhiteSpace($script:KeyPassword)) {
        throw "No keystore is loaded. Select a saved project or run setup."
    }
    $store = Resolve-ExistingPath $script:StoreFile $ScriptDir
    if (-not $store) { throw "Keystore not found: $($script:StoreFile)" }
    return @{
        storeFileAbsolute = $store
        storePassword     = $script:StorePassword
        keyAlias          = $script:KeyAlias
        keyPassword       = $script:KeyPassword
    }
}

function Invoke-Keytool {
    param([Parameter(Mandatory = $true)][string[]]$Args)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & keytool @Args 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }

    return [pscustomobject]@{
        ExitCode = $code
        Text     = ($output | ForEach-Object { "$_" }) -join "`n"
    }
}

function Get-KeystoreAliases([string]$store, [string]$storePass) {
    $list = Invoke-Keytool -Args @(
        "-list", "-v",
        "-keystore", $store,
        "-storepass", $storePass
    )
    if ($list.ExitCode -ne 0) {
        Write-Host $list.Text
        throw "Could not list aliases. Store password may be wrong, or the file is not a keystore."
    }
    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($list.Text, '(?im)^Alias name:\s*(.+)$')) {
        $name = $m.Groups[1].Value.Trim()
        if ($name -and -not $aliases.Contains($name)) { [void]$aliases.Add($name) }
    }
    return @($aliases)
}

function Test-KeystoreAccess($ks) {
    $keytool = Get-Command keytool -ErrorAction SilentlyContinue
    if (-not $keytool) {
        Write-Host "Warning: keytool not on PATH - skipping keystore password check." -ForegroundColor Yellow
        return $ks
    }

    Write-Host "Checking store password..."
    $list = Invoke-Keytool -Args @(
        "-list", "-v",
        "-keystore", $ks.storeFileAbsolute,
        "-storepass", $ks.storePassword,
        "-alias", $ks.keyAlias
    )
    if ($list.ExitCode -ne 0) {
        Write-Host $list.Text
        throw @"
storePassword is wrong (or alias '$($ks.keyAlias)' is missing).

Edit: $KeystorePropsFile
Test: keytool -list -keystore "$($ks.storeFileAbsolute)"
"@
    }
    Write-Host "  Store password OK (alias '$($ks.keyAlias)' found)."

    $isPkcs12 = $list.Text -match 'Keystore type:\s*PKCS12'
    if (-not $isPkcs12) {
        $type = Invoke-Keytool -Args @(
            "-list",
            "-keystore", $ks.storeFileAbsolute,
            "-storepass", $ks.storePassword
        )
        $isPkcs12 = $type.Text -match 'Keystore type:\s*PKCS12'
    }

    if ($isPkcs12) {
        Write-Host "  Keystore type: PKCS12"
        Write-Host "  Note: will try storePassword, then keyPassword, to unlock the private key."

        Write-Host "Checking private key access (PKCS12)..."
        $tmpJks = Join-Path $env:TEMP ("signing-script-keycheck-" + [guid]::NewGuid().ToString() + ".jks")
        $originalKeyPass = $ks.keyPassword
        $keyPassCandidates = @($ks.storePassword)
        if ($originalKeyPass -cne $ks.storePassword) {
            $keyPassCandidates += $originalKeyPass
        }

        try {
            $unlocked = $false
            foreach ($tryKeyPass in $keyPassCandidates) {
                if (Test-Path $tmpJks) { Remove-Item $tmpJks -Force -ErrorAction SilentlyContinue }
                $imp = Invoke-Keytool -Args @(
                    "-importkeystore", "-noprompt",
                    "-srckeystore", $ks.storeFileAbsolute,
                    "-srcstoretype", "PKCS12",
                    "-srcalias", $ks.keyAlias,
                    "-srcstorepass", $ks.storePassword,
                    "-srckeypass", $tryKeyPass,
                    "-destkeystore", $tmpJks,
                    "-deststoretype", "JKS",
                    "-destalias", $ks.keyAlias,
                    "-deststorepass", "tempcheck",
                    "-destkeypass", "tempcheck"
                )
                if ($imp.ExitCode -eq 0) {
                    $ks.keyPassword = $tryKeyPass
                    $unlocked = $true
                    if ($tryKeyPass -ceq $ks.storePassword) {
                        Write-Host "  Private key OK (using storePassword)."
                    } else {
                        Write-Host "  Private key OK (using keyPassword from keystore.properties)."
                    }
                    break
                }
            }
            if (-not $unlocked) {
                throw @"
Cannot unlock the private key in this PKCS12 keystore.

Tried storePassword and keyPassword from keystore.properties.
Convert/export the keystore so Java can read the private key, or recreate it
with matching store and key passwords.

See convert-pkcs12-dual.py in this folder if Android Studio used two passwords.
"@
            }
        }
        finally {
            if (Test-Path $tmpJks) { Remove-Item $tmpJks -Force -ErrorAction SilentlyContinue }
        }
        return $ks
    }

    Write-Host "Checking key password..."
    $key = Invoke-Keytool -Args @(
        "-keypasswd",
        "-keystore", $ks.storeFileAbsolute,
        "-alias", $ks.keyAlias,
        "-storepass", $ks.storePassword,
        "-keypass", $ks.keyPassword,
        "-new", $ks.keyPassword
    )
    $keyOk = ($key.ExitCode -eq 0) -or ($key.Text -match 'must be different|same as the old')
    if (-not $keyOk) {
        Write-Host $key.Text
        throw @"
keyPassword is wrong for alias '$($ks.keyAlias)'.

Edit keyPassword in: $KeystorePropsFile
"@
    }
    Write-Host "  Key password OK."
    return $ks
}

function New-SigningInitScript($ks) {
    $id = [guid]::NewGuid().ToString()
    $credsPath = Join-Path $env:TEMP ("signing-script-creds-" + $id + ".properties")
    $initPath = Join-Path $env:TEMP ("signing-script-init-" + $id + ".gradle")

    $storePath = $ks.storeFileAbsolute.Replace("\", "/")
    $utf8 = [System.Text.Encoding]::UTF8
    $storePassB64 = [Convert]::ToBase64String($utf8.GetBytes($ks.storePassword))
    $keyPassB64 = [Convert]::ToBase64String($utf8.GetBytes($ks.keyPassword))

    $creds = @(
        "storeFile=$storePath"
        "keyAlias=$($ks.keyAlias)"
        "storePasswordB64=$storePassB64"
        "keyPasswordB64=$keyPassB64"
    ) -join "`n"
    [System.IO.File]::WriteAllText($credsPath, $creds, [System.Text.UTF8Encoding]::new($false))

    $credsPathGroovy = $credsPath.Replace("\", "/")
    $init = @'
import java.util.Base64
import java.nio.charset.StandardCharsets

def credsFile = new File('__CREDS_PATH__')
def lines = credsFile.getText('UTF-8').readLines()
def map = [:]
lines.each { line ->
    def idx = line.indexOf('=')
    if (idx > 0) {
        map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim()
    }
}
def storeFilePath = map.storeFile
def keyAliasValue = map.keyAlias
def storePasswordValue = new String(Base64.decoder.decode(map.storePasswordB64), StandardCharsets.UTF_8)
def keyPasswordValue = new String(Base64.decoder.decode(map.keyPasswordB64), StandardCharsets.UTF_8)

gradle.projectsLoaded {
    rootProject.subprojects { sub ->
        sub.afterEvaluate {
            def androidExt = sub.extensions.findByName('android')
            if (androidExt == null) return
            if (!androidExt.hasProperty('signingConfigs')) return
            try {
                def configs = androidExt.signingConfigs
                def cfg = configs.findByName('signingScriptCliRelease')
                if (cfg == null) {
                    cfg = configs.create('signingScriptCliRelease')
                }
                cfg.storeFile = new File(storeFilePath)
                cfg.storePassword = storePasswordValue
                cfg.keyAlias = keyAliasValue
                cfg.keyPassword = keyPasswordValue
                def releaseType = androidExt.buildTypes.findByName('release')
                if (releaseType != null) {
                    releaseType.signingConfig = cfg
                }
            } catch (Throwable ignored) {
            }
        }
    }
}
'@
    $init = $init.Replace('__CREDS_PATH__', $credsPathGroovy)

    [System.IO.File]::WriteAllText($initPath, $init, [System.Text.UTF8Encoding]::new($false))
    $script:TempInitScript = $initPath
    $script:TempCredsFile = $credsPath
    return $initPath
}

function Remove-TempInitScript {
    if ($script:TempInitScript -and (Test-Path $script:TempInitScript)) {
        Remove-Item $script:TempInitScript -Force -ErrorAction SilentlyContinue
    }
    if ($script:TempCredsFile -and (Test-Path $script:TempCredsFile)) {
        Remove-Item $script:TempCredsFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-VersionNameFromText([string]$text) {
    if ($text -match 'versionName\s*=\s*"([^"]+)"') { return $Matches[1] }
    if ($text -match "versionName\s*=\s*'([^']+)'") { return $Matches[1] }
    if ($text -match 'versionName\s+"([^"]+)"') { return $Matches[1] }
    if ($text -match "versionName\s+'([^']+)'") { return $Matches[1] }
    return $null
}

function Get-BumpedVersionName([string]$name) {
    $parts = $name.Split(".")
    $allInt = $true
    foreach ($p in $parts) {
        if ($p -notmatch '^\d+$') { $allInt = $false; break }
    }
    if ($allInt -and $parts.Count -ge 2) {
        $last = $parts.Count - 1
        $parts[$last] = [string](([int]$parts[$last]) + 1)
        return ($parts -join ".")
    }
    if ($name -match '^(.*?)(\d+)$') {
        return $Matches[1] + ([string](([int]$Matches[2]) + 1))
    }
    throw "Cannot auto-increment versionName '$name'. Use a numeric form like 1.0 or 1.2.3."
}

function Bump-GradleVersion([string]$gradlePath) {
    $full = Join-Path $script:ProjectRoot $gradlePath
    if (-not (Test-Path $full)) { throw "Gradle file not found: $full" }

    $text = Get-Content $full -Raw -Encoding UTF8
    $script:VersionBackups[$gradlePath] = $text

    $oldCode = $null
    if ($text -match 'versionCode\s*=\s*(\d+)') {
        $oldCode = [int]$Matches[1]
        $newCode = $oldCode + 1
        $text = [regex]::Replace($text, 'versionCode\s*=\s*\d+', "versionCode = $newCode", 1)
    }
    elseif ($text -match 'versionCode\s+(\d+)') {
        $oldCode = [int]$Matches[1]
        $newCode = $oldCode + 1
        $text = [regex]::Replace($text, 'versionCode\s+\d+', "versionCode $newCode", 1)
    }
    else {
        throw "versionCode not found in $gradlePath"
    }

    $oldName = Get-VersionNameFromText $text
    if (-not $oldName) { throw "versionName not found in $gradlePath" }
    $newName = Get-BumpedVersionName $oldName

    if ($text -match 'versionName\s*=\s*"[^"]+"') {
        $text = [regex]::Replace($text, 'versionName\s*=\s*"[^"]+"', "versionName = `"$newName`"", 1)
    }
    elseif ($text -match "versionName\s*=\s*'[^']+'") {
        $text = [regex]::Replace($text, "versionName\s*=\s*'[^']+'", "versionName = '$newName'", 1)
    }
    elseif ($text -match 'versionName\s+"[^"]+"') {
        $text = [regex]::Replace($text, 'versionName\s+"[^"]+"', "versionName `"$newName`"", 1)
    }
    elseif ($text -match "versionName\s+'[^']+'") {
        $text = [regex]::Replace($text, "versionName\s+'[^']+'", "versionName '$newName'", 1)
    }
    else {
        throw "versionName not found in $gradlePath"
    }

    [System.IO.File]::WriteAllText($full, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  $gradlePath : versionName $newName  versionCode $newCode"
    return $newName
}

function Restore-GradleVersions {
    if ($script:VersionBackups.Count -eq 0) { return }
    Write-Host ""
    Write-Host "Build failed - restoring previous version numbers..."
    foreach ($gradlePath in $script:VersionBackups.Keys) {
        $full = Join-Path $script:ProjectRoot $gradlePath
        [System.IO.File]::WriteAllText($full, $script:VersionBackups[$gradlePath], [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Restored $gradlePath"
    }
}

function Get-GradleVersionName([string]$gradlePath) {
    $full = Join-Path $script:ProjectRoot $gradlePath
    if (-not (Test-Path $full)) { throw "Gradle file not found: $full" }
    $text = Get-Content $full -Raw -Encoding UTF8
    $name = Get-VersionNameFromText $text
    if (-not $name) { throw "versionName not found in $gradlePath" }
    return $name
}

function Copy-Renamed([string]$modulePath, [string]$label, [string]$folder, [string]$ver) {
    $apkSrc = Get-ChildItem (Join-Path $script:ProjectRoot "$modulePath\build\outputs\apk\release\*.apk") -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "-unsigned" } | Select-Object -First 1
    $aabSrc = Get-ChildItem (Join-Path $script:ProjectRoot "$modulePath\build\outputs\bundle\release\*.aab") -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $modId = if ([string]::IsNullOrWhiteSpace($modulePath) -or $modulePath -eq ".") { "root project" } else { $modulePath.Replace('\', ':') }
    if (-not $apkSrc) { throw "No APK for $modId" }
    if (-not $aabSrc) { throw "No AAB for $modId" }

    $destDir = Join-Path $script:OutDir $folder
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    $safeLabel = Get-SafeFileName $label
    $safeVer = Get-SafeFileName $ver
    $apkDest = Join-Path $destDir "$safeLabel $safeVer.apk"
    $aabDest = Join-Path $destDir "$safeLabel $safeVer.aab"
    Copy-Item $apkSrc.FullName $apkDest -Force
    Copy-Item $aabSrc.FullName $aabDest -Force
    Write-Host "  -> $apkDest"
    Write-Host "  -> $aabDest"
}

function Show-DetectedModules($modules) {
    Write-Host ""
    Write-Host "Detected application modules:" -ForegroundColor Cyan
    foreach ($m in $modules) {
        $gradleId = if ([string]::IsNullOrWhiteSpace($m.Gradle)) { "(root project)" } else { ":$($m.Gradle)" }
        Write-Host ("  - {0,-18} {1}" -f $m.Folder, "$gradleId  ($($m.GradleFile))")
    }
    Write-Host ""
}

function Show-ProjectPicker {
    param($Projects)

    $Projects = @($Projects)
    $count = $Projects.Count
    $lastId = Get-LastProjectId
    $cursor = 0
    for ($i = 0; $i -lt $count; $i++) {
        if ($Projects[$i].Id -eq $lastId) { $cursor = $i; break }
    }

    while ($true) {
        $entries = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $count; $i++) {
            $p = $Projects[$i]
            $ready = Test-SavedProjectReady $p
            $mark = ""
            if ($p.Id -eq $lastId) { $mark = "  (last used)" }
            if (-not $ready) { $mark += "  [needs setup]" }
            [void]$entries.Add([pscustomobject]@{
                    Kind        = "project"
                    Project     = $p
                    Title       = $p.AppName + $mark
                    Subtitle    = $p.ProjectRoot
                })
        }
        [void]$entries.Add([pscustomobject]@{ Kind = "spacer"; Title = "" })
        [void]$entries.Add([pscustomobject]@{ Kind = "add"; Title = ">>> Add new project" })
        [void]$entries.Add([pscustomobject]@{ Kind = "remove"; Title = ">>> Remove highlighted project" })
        [void]$entries.Add([pscustomobject]@{ Kind = "cancel"; Title = ">>> Cancel" })

        $selectable = @()
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($entries[$i].Kind -ne "spacer") { $selectable += $i }
        }
        if ($selectable -notcontains $cursor) { $cursor = $selectable[0] }

        Clear-Host
        Show-Banner
        Show-Separator
        Write-Host "  Saved projects"
        Show-Separator
        Write-Host "  Select an app to restore its project"
        Write-Host "  path, keystore, alias, and passwords."
        Write-Host ""
        Write-Host "  Up/Down  move     Enter  open / run"
        Write-Host "  Delete   remove highlighted project"
        Write-Host ""

        for ($i = 0; $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            $active = ($i -eq $cursor)
            $prefix = if ($active) { " > " } else { "   " }
            $color = if ($active) { "Cyan" } else { "White" }
            if ($e.Kind -eq "spacer") {
                Write-Host ""
                continue
            }
            if ($e.Kind -eq "project") {
                Write-Host ($prefix + $e.Title) -ForegroundColor $color
                $subColor = if ($active) { "Cyan" } else { "DarkGray" }
                Write-Host ("    " + $e.Subtitle) -ForegroundColor $subColor
            }
            else {
                Write-Host ($prefix + $e.Title) -ForegroundColor $color
            }
        }

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $vk = $key.VirtualKeyCode
        $kind = $entries[$cursor].Kind

        if ($vk -eq 38) {
            $idx = [array]::IndexOf($selectable, $cursor)
            if ($idx -lt 0) { $idx = 0 }
            $cursor = $selectable[([Math]::Max(0, $idx - 1))]
        }
        elseif ($vk -eq 40) {
            $idx = [array]::IndexOf($selectable, $cursor)
            if ($idx -lt 0) { $idx = 0 }
            $cursor = $selectable[([Math]::Min($selectable.Count - 1, $idx + 1))]
        }
        elseif ($vk -eq 27) {
            return $null
        }
        elseif ($vk -eq 46) {
            if ($kind -eq "project") {
                return [pscustomobject]@{ Action = "remove"; Project = $entries[$cursor].Project }
            }
            Write-Host ""
            Write-Host "Highlight a saved project first, then press Delete." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
        elseif ($vk -eq 13) {
            if ($kind -eq "cancel") { return $null }
            if ($kind -eq "add") { return [pscustomobject]@{ Action = "add" } }
            if ($kind -eq "remove") {
                $target = $null
                for ($i = $cursor; $i -ge 0; $i--) {
                    if ($entries[$i].Kind -eq "project") { $target = $entries[$i].Project; break }
                }
                if (-not $target -and $count -gt 0) { $target = $Projects[0] }
                if (-not $target) {
                    Write-Host ""
                    Write-Host "No saved project to remove." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                }
                return [pscustomobject]@{ Action = "remove"; Project = $target }
            }
            if ($kind -eq "project") {
                return [pscustomobject]@{ Action = "select"; Project = $entries[$cursor].Project }
            }
        }
    }
}

function Invoke-SetupWizard {
    Clear-Host
    Show-Banner
    $editing = -not [string]::IsNullOrWhiteSpace($script:ProjectId)
    if ($editing) {
        Write-Host "  Edit saved project" -ForegroundColor Yellow
    }
    else {
        Write-Host "  Add a new project" -ForegroundColor Yellow
    }
    Show-Separator
    Write-Host ""

    $defaultRoot = $script:ProjectRoot
    while ($true) {
        $root = Read-PlainPath "Android Studio project path" $defaultRoot
        if ([string]::IsNullOrWhiteSpace($root)) {
            Write-Host "  Project path is required." -ForegroundColor Yellow
            continue
        }
        try {
            Test-AndroidStudioProject $root
            $script:ProjectRoot = (Resolve-Path $root).Path
            break
        }
        catch {
            Write-Host "  $_" -ForegroundColor Red
            $defaultRoot = $root
        }
    }

    $detectedName = Get-DefaultAppName $script:ProjectRoot
    $defaultName = $script:AppName
    if (-not $defaultName) { $defaultName = $detectedName }
    $script:AppName = Read-PlainText "App display name (used in the project list and filenames)" $defaultName
    if ([string]::IsNullOrWhiteSpace($script:AppName)) { $script:AppName = $detectedName }

    $defaultOut = $script:OutDir
    if (-not $defaultOut) { $defaultOut = Join-Path $env:USERPROFILE "Desktop\$($script:AppName)" }
    $out = Read-PlainPath "Output folder for APK / AAB" $defaultOut
    if ([string]::IsNullOrWhiteSpace($out)) { $out = $defaultOut }
    if (-not [IO.Path]::IsPathRooted($out)) { $out = Join-Path (Get-Location) $out }
    $script:OutDir = $out

    $modules = Find-AppModules $script:ProjectRoot $script:AppName
    Show-DetectedModules $modules

    Write-Host "Keystore (leave the file where it is; only the path is saved)" -ForegroundColor Cyan
    $defaultStore = $script:StoreFile

    $storeAbs = $null
    while ($true) {
        $store = Read-PlainPath "Keystore file (.jks / .p12 / .keystore)" $defaultStore
        if ([string]::IsNullOrWhiteSpace($store)) {
            Write-Host "  Keystore path is required." -ForegroundColor Yellow
            continue
        }
        $storeAbs = Resolve-ExistingPath $store $ScriptDir
        if (-not $storeAbs) {
            Write-Host "  File not found: $store" -ForegroundColor Red
            $defaultStore = $store
            continue
        }
        break
    }

    $storePass = $null
    if ($editing -and -not [string]::IsNullOrEmpty($script:StorePassword)) {
        $entered = Read-OptionalPassword "Store password (Enter to keep saved)"
        if ([string]::IsNullOrEmpty($entered)) { $storePass = $script:StorePassword } else { $storePass = $entered }
    }
    else {
        $storePass = Read-RequiredPassword "Store password"
    }

    $aliases = @()
    $keytool = Get-Command keytool -ErrorAction SilentlyContinue
    if ($keytool) {
        try {
            $aliases = @(Get-KeystoreAliases $storeAbs $storePass)
        }
        catch {
            Write-Host "  $_" -ForegroundColor Red
            throw
        }
    }

    $defaultAlias = $script:KeyAlias
    if (-not $defaultAlias -and $aliases.Count -eq 1) { $defaultAlias = $aliases[0] }

    if ($aliases.Count -gt 0) {
        Write-Host "  Aliases in this keystore:"
        for ($i = 0; $i -lt $aliases.Count; $i++) {
            Write-Host "    $($i + 1)) $($aliases[$i])"
        }
    }

    $alias = $null
    while ([string]::IsNullOrWhiteSpace($alias)) {
        $entered = Read-PlainText "Key alias (number or name)" $defaultAlias
        if ($entered -match '^\d+$' -and $aliases.Count -gt 0) {
            $idx = [int]$entered - 1
            if ($idx -ge 0 -and $idx -lt $aliases.Count) {
                $alias = $aliases[$idx]
            }
            else {
                Write-Host "  Invalid number." -ForegroundColor Yellow
            }
        }
        else {
            $alias = $entered
        }
        if ([string]::IsNullOrWhiteSpace($alias)) {
            Write-Host "  Alias is required." -ForegroundColor Yellow
        }
    }

    $keyPass = $null
    if ($editing -and -not [string]::IsNullOrEmpty($script:KeyPassword)) {
        $entered = Read-OptionalPassword "Key password (Enter to keep saved)"
        if ([string]::IsNullOrEmpty($entered)) { $keyPass = $script:KeyPassword } else { $keyPass = $entered }
    }
    else {
        $keyPass = Read-OptionalPassword "Key password (Enter = same as store password)"
        if ([string]::IsNullOrEmpty($keyPass)) { $keyPass = $storePass }
    }

    $ks = @{
        storeFileAbsolute = $storeAbs
        storePassword     = $storePass
        keyAlias          = $alias
        keyPassword       = $keyPass
    }

    Write-Host ""
    $ks = Test-KeystoreAccess $ks

    $script:StoreFile = $ks.storeFileAbsolute
    $script:StorePassword = $ks.storePassword
    $script:KeyAlias = $ks.keyAlias
    $script:KeyPassword = $ks.keyPassword

    $sameRoot = Find-SavedProjectByRoot $script:ProjectRoot
    if (-not $editing -and $sameRoot) {
        $script:ProjectId = $sameRoot.Id
        Write-Host "  This project path was already saved as '$($sameRoot.AppName)' - updating it." -ForegroundColor Yellow
    }

    $savedPath = Save-CurrentProject

    Write-Host ""
    Write-Host "Saved project: $($script:AppName)" -ForegroundColor Cyan
    Write-Host "  $savedPath"
    Write-Host "  Keystore: $storeAbs"
    Write-Host ""
    Write-Host "Press Enter to continue..."
    [void](Read-Host)
    return $modules
}

function Show-ReleaseMenu {
    param($Modules)

    $Modules = @($Modules)
    $count = $Modules.Count
    $on = New-Object bool[] $count
    for ($i = 0; $i -lt $count; $i++) { $on[$i] = $true }
    $bump = $true
    $cursor = 0

    function Mark([bool]$flag) { if ($flag) { "[X]" } else { "[ ]" } }

    while ($true) {
        $allOn = $true
        for ($i = 0; $i -lt $count; $i++) { if (-not $on[$i]) { $allOn = $false } }

        $entries = New-Object System.Collections.Generic.List[object]
        [void]$entries.Add([pscustomobject]@{ Kind = "all"; Text = "$(Mark $allOn) Select All" })
        for ($i = 0; $i -lt $count; $i++) {
            $m = $Modules[$i]
            $gradleId = if ([string]::IsNullOrWhiteSpace($m.Gradle)) { "root project" } else { ":$($m.Gradle)" }
            [void]$entries.Add([pscustomobject]@{
                    Kind        = "module"
                    ModuleIndex = $i
                    Text        = "$(Mark $on[$i]) $($m.Folder)   ($gradleId)"
                })
        }
        [void]$entries.Add([pscustomobject]@{ Kind = "spacer"; Text = "" })
        [void]$entries.Add([pscustomobject]@{ Kind = "bump"; Text = "$(Mark $bump) Auto-increment version code & app version" })
        [void]$entries.Add([pscustomobject]@{ Kind = "spacer"; Text = "" })
        [void]$entries.Add([pscustomobject]@{ Kind = "switch"; Text = ">>> Switch project" })
        [void]$entries.Add([pscustomobject]@{ Kind = "edit"; Text = ">>> Edit this project / keystore" })
        [void]$entries.Add([pscustomobject]@{ Kind = "build"; Text = ">>> Build selected" })
        [void]$entries.Add([pscustomobject]@{ Kind = "cancel"; Text = ">>> Cancel" })

        $selectable = @()
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($entries[$i].Kind -ne "spacer") { $selectable += $i }
        }
        if ($selectable -notcontains $cursor) { $cursor = $selectable[0] }

        Clear-Host
        Show-Banner
        $info = @(
            " Project : $script:ProjectRoot"
            " Output  : $script:OutDir"
            " App     : $script:AppName"
        )
        Show-Separator -FitTo $info
        Write-Host " Project : $script:ProjectRoot"
        Write-Host " Output  : $script:OutDir"
        Write-Host " App     : $script:AppName"
        Show-Separator -FitTo $info
        Write-Host ""
        Write-Host "  Use Up/Down to move, Space to toggle,"
        Write-Host "  Enter to activate Build / Switch / Edit / Cancel."
        Write-Host ""

        for ($i = 0; $i -lt $entries.Count; $i++) {
            $prefix = if ($i -eq $cursor) { " > " } else { "   " }
            $line = $prefix + $entries[$i].Text
            if ($i -eq $cursor) {
                Write-Host $line -ForegroundColor Cyan
            }
            else {
                Write-Host $line
            }
        }

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $vk = $key.VirtualKeyCode
        $kind = $entries[$cursor].Kind

        if ($vk -eq 38) {
            $idx = [array]::IndexOf($selectable, $cursor)
            if ($idx -lt 0) { $idx = 0 }
            $cursor = $selectable[([Math]::Max(0, $idx - 1))]
        }
        elseif ($vk -eq 40) {
            $idx = [array]::IndexOf($selectable, $cursor)
            if ($idx -lt 0) { $idx = 0 }
            $cursor = $selectable[([Math]::Min($selectable.Count - 1, $idx + 1))]
        }
        elseif ($vk -eq 27) {
            return $null
        }
        elseif ($vk -eq 32 -or ($vk -eq 13 -and $kind -in @("all", "module", "bump"))) {
            switch ($kind) {
                "all" {
                    $newAll = -not $allOn
                    for ($i = 0; $i -lt $count; $i++) { $on[$i] = $newAll }
                }
                "module" {
                    $mi = $entries[$cursor].ModuleIndex
                    $on[$mi] = -not $on[$mi]
                }
                "bump" { $bump = -not $bump }
            }
        }
        elseif ($vk -eq 13) {
            if ($kind -eq "cancel") { return [pscustomobject]@{ Action = "back" } }
            if ($kind -eq "switch") {
                return [pscustomobject]@{ Action = "switch" }
            }
            if ($kind -eq "edit") {
                return [pscustomobject]@{ Action = "edit" }
            }
            if ($kind -eq "build") {
                $any = $false
                for ($i = 0; $i -lt $count; $i++) { if ($on[$i]) { $any = $true } }
                if (-not $any) {
                    Write-Host ""
                    Write-Host "Select at least one module." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                }
                $selected = @()
                for ($i = 0; $i -lt $count; $i++) {
                    if ($on[$i]) { $selected += $Modules[$i] }
                }
                return [pscustomobject]@{
                    Action       = "build"
                    Modules      = $selected
                    BumpVersions = $bump
                }
            }
        }
    }
}

function Invoke-ReleaseBuild($selectedModules, [bool]$bumpVersions) {
    $selectedModules = @($selectedModules)
    Clear-Host
    Show-Banner
    Write-Host "Signing Script - release build"
    Write-Host "Project : $script:ProjectRoot"
    Write-Host "Output  : $script:OutDir"
    Write-Host "Apps    : $($selectedModules.Folder -join ', ')"
    Write-Host "Bump    : $(if ($bumpVersions) { 'Yes' } else { 'No' })"
    Write-Host ""

    $script:VersionBackups = @{}

    try {
        Test-AndroidStudioProject $script:ProjectRoot

        $ks = Get-ActiveKeystore
        $ks = Test-KeystoreAccess $ks
        $script:StorePassword = $ks.storePassword
        $script:KeyPassword = $ks.keyPassword
        [void](Save-CurrentProject)
        New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null

        $versions = @{}
        if ($bumpVersions) {
            Write-Host ""
            Write-Host "Bumping versions..."
            foreach ($m in $selectedModules) {
                $versions[$m.Gradle] = Bump-GradleVersion $m.GradleFile
            }
        }
        else {
            Write-Host ""
            Write-Host "Keeping current versions (auto-increment off)..."
            foreach ($m in $selectedModules) {
                $versions[$m.Gradle] = Get-GradleVersionName $m.GradleFile
                Write-Host "  $($m.GradleFile) : versionName $($versions[$m.Gradle])"
            }
        }

        Set-Location $script:ProjectRoot
        $Gradle = Get-GradleWrapper $script:ProjectRoot
        if (-not $Gradle) { throw "gradlew.bat not found in project root" }

        $initScript = New-SigningInitScript $ks

        $tasks = @()
        foreach ($m in $selectedModules) {
            if ([string]::IsNullOrWhiteSpace($m.Gradle)) {
                $tasks += "assembleRelease"
                $tasks += "bundleRelease"
            }
            else {
                $tasks += ":$($m.Gradle):assembleRelease"
                $tasks += ":$($m.Gradle):bundleRelease"
            }
        }

        Write-Host ""
        Write-Host "Building release APK + AAB..."
        $gradleExit = Invoke-GradleWithProgress -Gradle $Gradle -Tasks $tasks -InitScript $initScript
        if ($gradleExit -ne 0) { throw "Gradle build failed (exit $gradleExit)" }

        Write-Host ""
        Write-Host "Copying to $script:OutDir ..."
        foreach ($m in $selectedModules) {
            Copy-Renamed $m.Path $m.Label $m.Folder $versions[$m.Gradle]
        }

        Write-Host ""
        Write-Host "Done. Files are in: $script:OutDir" -ForegroundColor Cyan
        if ($bumpVersions) {
            Write-Host "Remember: version bumps were written into the Gradle files - commit them if you want."
        }
    }
    catch {
        Restore-GradleVersions
        throw
    }
    finally {
        Remove-TempInitScript
    }
}

# --- start ---
try {
    if ($PSBoundParameters.ContainsKey("ProjectRoot") -and $ProjectRoot) {
        $script:ProjectRoot = $ProjectRoot.Trim().Trim('"')
    }
    if ($PSBoundParameters.ContainsKey("OutDir") -and $OutDir) {
        $script:OutDir = $OutDir.Trim().Trim('"')
    }
    if ($PSBoundParameters.ContainsKey("AppName") -and $AppName) {
        $script:AppName = $AppName.Trim()
    }

    Import-LegacyProjectIfNeeded

    $showPicker = $true
    if (-not $Reconfigure -and $PSBoundParameters.ContainsKey("ProjectRoot") -and $ProjectRoot) {
        $matched = Find-SavedProjectByRoot $script:ProjectRoot
        if ($matched) {
            Use-SavedProject $matched
            $showPicker = $false
        }
    }

    while ($true) {
        $saved = @(Get-SavedProjects)

        if ($showPicker) {
            if ($saved.Count -eq 0) {
                Clear-CurrentProject -KeepCli
                [void](Invoke-SetupWizard)
            }
            else {
                $pick = Show-ProjectPicker -Projects $saved
                if ($null -eq $pick) {
                    Write-Host "Cancelled."
                    exit 0
                }
                if ($pick.Action -eq "add") {
                    Clear-CurrentProject
                    [void](Invoke-SetupWizard)
                }
                elseif ($pick.Action -eq "remove") {
                    Write-Host ""
                    $confirm = Read-Host "Remove '$($pick.Project.AppName)' from saved projects? (y/N)"
                    if ($confirm -match '^[yY]') {
                        Remove-SavedProject $pick.Project
                        Write-Host "Removed." -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                    continue
                }
                elseif ($pick.Action -eq "select") {
                    Use-SavedProject $pick.Project
                    if (-not (Test-SavedProjectReady $pick.Project)) {
                        Write-Host ""
                        Write-Host "This saved project needs setup (path or keystore missing)." -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                        [void](Invoke-SetupWizard)
                    }
                }
            }
        }
        $showPicker = $true

        if ($PSBoundParameters.ContainsKey("OutDir") -and $OutDir) {
            $script:OutDir = $OutDir.Trim().Trim('"')
        }
        if ($PSBoundParameters.ContainsKey("AppName") -and $AppName) {
            $script:AppName = $AppName.Trim()
        }

        $modules = Find-AppModules $script:ProjectRoot $script:AppName
        $choice = Show-ReleaseMenu -Modules $modules
        if ($null -eq $choice -or $choice.Action -eq "back" -or $choice.Action -eq "switch") {
            continue
        }
        if ($choice.Action -eq "edit") {
            [void](Invoke-SetupWizard)
            $showPicker = $false
            continue
        }

        Invoke-ReleaseBuild $choice.Modules ([bool]$choice.BumpVersions)
        break
    }
}
catch {
    Write-Host ""
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Remove-TempInitScript
}
