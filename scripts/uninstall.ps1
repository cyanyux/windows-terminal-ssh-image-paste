param(
    [string]$InstallDir = "$HOME\bin",
    [switch]$RemoveState
)

$ErrorActionPreference = "Stop"

$StartupFile = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\ClaudeSshImagePaste.cmd"
$StateDir = Join-Path $env:LOCALAPPDATA "ClaudeSshImagePaste"
$ProfilePaths = @(
    (Join-Path $HOME "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"),
    (Join-Path $HOME "Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
)
$ProfileBlockStart = "# >>> terminal-ssh-image-paste >>>"
$ProfileBlockEnd = "# <<< terminal-ssh-image-paste <<<"

function Write-Info([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
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

    return $Content
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

    return ($lines -join "`r`n")
}

function Remove-ProfileBlock([string]$ProfilePath) {
    if (-not (Test-Path $ProfilePath)) {
        return
    }

    $content = Get-Content -Path $ProfilePath -Raw
    $content = Remove-LegacyProfileEntries -Content $content
    $updated = Remove-ManagedProfileBlocks -Content $content
    Set-Content -Path $ProfilePath -Value $updated.TrimEnd("`r", "`n") + "`r`n" -Encoding UTF8
}

Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" |
    Where-Object { $_.CommandLine -like "*ClaudeSshImagePaste.ahk*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($fileName in @("ClaudeSsh.ps1", "ClaudeSshImagePaste.ps1", "ClaudeSshImagePaste.ahk")) {
    $target = Join-Path $InstallDir $fileName
    if (Test-Path $target) {
        Remove-Item -Path $target -Force
    }
}

if (Test-Path $StartupFile) {
    Remove-Item -Path $StartupFile -Force
}

foreach ($profilePath in $ProfilePaths) {
    Remove-ProfileBlock $profilePath
}

if ($RemoveState -and (Test-Path $StateDir)) {
    Remove-Item -Path $StateDir -Recurse -Force
}

Write-Info "Uninstalled terminal-ssh-image-paste"
