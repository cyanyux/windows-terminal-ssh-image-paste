param(
    [string]$InstallDir = "$HOME\bin",
    [switch]$InstallAutoHotkey
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourceBinDir = Join-Path $RepoRoot "bin"
$TargetBinDir = $InstallDir
$StartupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$StartupFile = Join-Path $StartupDir "ClaudeSshImagePaste.cmd"
$ProfilePaths = @(
    (Join-Path $HOME "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"),
    (Join-Path $HOME "Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
)
$ProfileBlockStart = "# >>> terminal-ssh-image-paste >>>"
$ProfileBlockEnd = "# <<< terminal-ssh-image-paste <<<"

function Write-Info([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-AutoHotkey {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    if (-not $InstallAutoHotkey) {
        throw "AutoHotkey v2 not found. Re-run with -InstallAutoHotkey or install it manually."
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "AutoHotkey v2 not found and winget is unavailable."
    }

    Write-Info "Installing AutoHotkey v2 with winget"
    winget install --exact --id AutoHotkey.AutoHotkey --accept-package-agreements --accept-source-agreements

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "AutoHotkey v2 installation did not produce AutoHotkey64.exe in an expected location."
}

function Copy-Binaries {
    Ensure-Directory $TargetBinDir
    foreach ($fileName in @("ClaudeSsh.ps1", "ClaudeSshImagePaste.ps1", "ClaudeSshImagePaste.ahk")) {
        Copy-Item -Path (Join-Path $SourceBinDir $fileName) -Destination (Join-Path $TargetBinDir $fileName) -Force
    }
}

function New-ProfileBlock([string]$ResolvedBinDir) {
    return @"
$ProfileBlockStart
function cssh {
    & "$ResolvedBinDir\ClaudeSsh.ps1" @args
}

function cssh-here {
    & "$ResolvedBinDir\ClaudeSsh.ps1" -Here @args
}

function cssh-on {
    & "$ResolvedBinDir\ClaudeSshImagePaste.ps1" set-session @args
}

function cssh-off {
    & "$ResolvedBinDir\ClaudeSshImagePaste.ps1" clear-session @args
}

function cssh-status {
    & "$ResolvedBinDir\ClaudeSshImagePaste.ps1" status @args
}
$ProfileBlockEnd
"@
}

function Remove-LegacyProfileEntries([string]$Content) {
    $patterns = @(
        '(?ms)^\s*function\s+cssh\s*\{.*?ClaudeSsh\.ps1.*?^\}\s*',
        '(?ms)^\s*function\s+cssh-here\s*\{.*?ClaudeSsh\.ps1.*?^\}\s*',
        '(?ms)^\s*function\s+cssh-on\s*\{.*?ClaudeSshImagePaste\.ps1.*?^\}\s*',
        '(?ms)^\s*function\s+cssh-off\s*\{.*?ClaudeSshImagePaste\.ps1.*?^\}\s*',
        '(?ms)^\s*function\s+cssh-status\s*\{.*?ClaudeSshImagePaste\.ps1.*?^\}\s*'
    )

    foreach ($pattern in $patterns) {
        $Content = [regex]::Replace($Content, $pattern, "", "Multiline")
    }

    return $Content.TrimEnd("`r", "`n")
}

function Remove-ManagedProfileBlocks([string]$Content) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $insideManagedBlock = $false

    foreach ($line in ($Content -split "`r?`n")) {
        $trimmed = $line.Trim([char]0xFEFF)
        if ($trimmed -eq $ProfileBlockStart) {
            $insideManagedBlock = $true
            continue
        }
        if ($trimmed -eq $ProfileBlockEnd) {
            $insideManagedBlock = $false
            continue
        }
        if (-not $insideManagedBlock) {
            $lines.Add($line)
        }
    }

    return ($lines -join "`r`n").TrimEnd("`r", "`n")
}

function Update-Profile([string]$ProfilePath, [string]$ResolvedBinDir) {
    Ensure-Directory (Split-Path -Parent $ProfilePath)
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }

    $profileBlock = New-ProfileBlock -ResolvedBinDir $ResolvedBinDir
    $content = Get-Content -Path $ProfilePath -Raw
    $content = Remove-LegacyProfileEntries -Content $content
    $content = Remove-ManagedProfileBlocks -Content $content
    if ($content -and -not $content.EndsWith("`n")) {
        $content += "`r`n"
    }
    $content += "`r`n$profileBlock`r`n"

    Set-Content -Path $ProfilePath -Value $content -Encoding UTF8
}

function Write-StartupCmd([string]$AutoHotkeyExe, [string]$ResolvedBinDir) {
    Ensure-Directory $StartupDir
    $cmd = @"
@echo off
start "" "$AutoHotkeyExe" "$ResolvedBinDir\ClaudeSshImagePaste.ahk"
"@
    Set-Content -Path $StartupFile -Value $cmd -Encoding ASCII
}

function Restart-AutoHotkey([string]$AutoHotkeyExe) {
    Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" |
        Where-Object { $_.CommandLine -like "*ClaudeSshImagePaste.ahk*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Start-Sleep -Milliseconds 300
    Start-Process -FilePath $AutoHotkeyExe -ArgumentList (Join-Path $TargetBinDir "ClaudeSshImagePaste.ahk") | Out-Null
}

Copy-Binaries
$resolvedBinDir = (Resolve-Path $TargetBinDir).Path
$autoHotkeyExe = Ensure-AutoHotkey
foreach ($profilePath in $ProfilePaths) {
    Update-Profile $profilePath $resolvedBinDir
}
Write-StartupCmd -AutoHotkeyExe $autoHotkeyExe -ResolvedBinDir $resolvedBinDir
Restart-AutoHotkey -AutoHotkeyExe $autoHotkeyExe

Write-Info "Installed terminal-ssh-image-paste"
Write-Host "Open a PowerShell tab and run: cssh user@host"
