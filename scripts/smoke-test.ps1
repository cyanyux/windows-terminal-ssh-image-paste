param(
    [string]$BinDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "bin")
)

$ErrorActionPreference = "Stop"

function Test-PowerShellFile([string]$Path) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failed for $Path`n$($errors | ForEach-Object Message | Out-String)"
    }
}

function Get-AutoHotkeyExe {
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
    throw "AutoHotkey v2 executable not found."
}

function Test-AutoHotkeyLoad([string]$ExePath, [string]$ScriptPath) {
    $stderrPath = Join-Path $env:TEMP ("ahk-smoke-{0}.err" -f [guid]::NewGuid().ToString("N"))
    try {
        $process = Start-Process -FilePath $ExePath -ArgumentList $ScriptPath -PassThru -WindowStyle Hidden -RedirectStandardError $stderrPath
        Start-Sleep -Milliseconds 700

        if ($process.HasExited -and $process.ExitCode -ne 0) {
            $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
            throw "AutoHotkey failed to load $ScriptPath`n$stderr"
        }
    } finally {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $stderrPath) {
            Remove-Item -Path $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$psFiles = @(
    (Join-Path $BinDir "ClaudeSsh.ps1"),
    (Join-Path $BinDir "ClaudeSshImagePaste.ps1")
)

foreach ($psFile in $psFiles) {
    Test-PowerShellFile $psFile
}

$ahkExe = Get-AutoHotkeyExe
$ahkFile = Join-Path $BinDir "ClaudeSshImagePaste.ahk"
Test-AutoHotkeyLoad -ExePath $ahkExe -ScriptPath $ahkFile

Write-Host "Smoke test passed" -ForegroundColor Green
