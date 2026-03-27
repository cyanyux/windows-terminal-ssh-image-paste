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

function Invoke-Helper([string]$HelperPath, [string[]]$ArgumentList) {
    $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $HelperPath @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Helper command failed:`n$($output | Out-String)"
    }
    return ($output | ForEach-Object { "$_" }) -join "`n"
}

function New-LocalHelperCopy([string]$SourceHelperPath) {
    $targetDir = Join-Path $env:TEMP ("csship-smoke-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $targetPath = Join-Path $targetDir "ClaudeSshImagePaste.ps1"
    Copy-Item -Path $SourceHelperPath -Destination $targetPath -Force
    return $targetPath
}

function Test-AutoHotkeyLoad([string]$ExePath, [string]$ScriptPath) {
    $localScriptDir = $null
    $resolvedScriptPath = $ScriptPath
    $stderrPath = Join-Path $env:TEMP ("ahk-smoke-{0}.err" -f [guid]::NewGuid().ToString("N"))
    try {
        if ($ScriptPath -like "\\wsl.localhost\*") {
            $localScriptDir = Join-Path $env:TEMP ("ahk-smoke-script-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $localScriptDir -Force | Out-Null
            $resolvedScriptPath = Join-Path $localScriptDir (Split-Path -Leaf $ScriptPath)
            Copy-Item -Path $ScriptPath -Destination $resolvedScriptPath -Force
            $helperScriptPath = Join-Path (Split-Path -Parent $ScriptPath) "ClaudeSshImagePaste.ps1"
            if (Test-Path $helperScriptPath) {
                Copy-Item -Path $helperScriptPath -Destination (Join-Path $localScriptDir "ClaudeSshImagePaste.ps1") -Force
            }
        }

        $process = Start-Process -FilePath $ExePath -ArgumentList $resolvedScriptPath -PassThru -WindowStyle Hidden -RedirectStandardError $stderrPath
        Start-Sleep -Milliseconds 700

        if ($process.HasExited -and $process.ExitCode -ne 0) {
            $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
            throw "AutoHotkey failed to load $resolvedScriptPath`n$stderr"
        }
    } finally {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $stderrPath) {
            Remove-Item -Path $stderrPath -Force -ErrorAction SilentlyContinue
        }
        if ($localScriptDir -and (Test-Path $localScriptDir)) {
            Remove-Item -Path $localScriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ReservationLocking([string]$HelperPath) {
    $originalLocalAppData = $env:LOCALAPPDATA
    $stateDir = Join-Path $env:TEMP ("csship-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $localHelperPath = $null

    try {
        $env:LOCALAPPDATA = $stateDir

        $localHelperPath = New-LocalHelperCopy -SourceHelperPath $HelperPath
        $sameA = Invoke-Helper $localHelperPath @("reserve-path", "-Target", "user@host", "-RemoteDir", "/tmp/i", "-Hash", "same-hash")
        $sameB = Invoke-Helper $localHelperPath @("reserve-path", "-Target", "user@host", "-RemoteDir", "/tmp/i", "-Hash", "same-hash")
        if ($sameA -ne $sameB) {
            throw "Same hash should resolve to the same reserved path. Got '$sameA' and '$sameB'."
        }

        $jobs = @()
        try {
            foreach ($i in 1..8) {
                $jobs += Start-Job -ScriptBlock {
                    param($ResolvedHelperPath, $ResolvedStateDir, $ResolvedHash)
                    $env:LOCALAPPDATA = $ResolvedStateDir
                    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ResolvedHelperPath reserve-path -Target "user@host" -RemoteDir "/tmp/i" -Hash $ResolvedHash
                } -ArgumentList $localHelperPath, $stateDir, ("hash-{0}" -f $i)
            }

            Wait-Job -Job $jobs | Out-Null
            $results = @($jobs | Receive-Job)
            if ($results.Count -ne 8) {
                throw "Expected 8 reservation results, got $($results.Count)."
            }

            $normalized = @($results | ForEach-Object { "$_".Trim() })
            $unique = @($normalized | Sort-Object -Unique)
            if ($unique.Count -ne $normalized.Count) {
                throw "Concurrent reservations returned duplicate paths:`n$($normalized -join "`n")"
            }
        } finally {
            if ($jobs.Count -gt 0) {
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        $env:LOCALAPPDATA = $originalLocalAppData
        if ($localHelperPath) {
            $localHelperDir = Split-Path -Parent $localHelperPath
            if (Test-Path $localHelperDir) {
                Remove-Item -Path $localHelperDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path $stateDir) {
            Remove-Item -Path $stateDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-SessionStateLocking([string]$HelperPath) {
    $originalLocalAppData = $env:LOCALAPPDATA
    $stateDir = Join-Path $env:TEMP ("csship-session-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $localHelperPath = $null

    try {
        $env:LOCALAPPDATA = $stateDir
        $localHelperPath = New-LocalHelperCopy -SourceHelperPath $HelperPath

        $jobs = @()
        try {
            foreach ($i in 1..8) {
                $jobs += Start-Job -ScriptBlock {
                    param($ResolvedHelperPath, $ResolvedStateDir, $n)
                    $env:LOCALAPPDATA = $ResolvedStateDir
                    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ResolvedHelperPath set-session -Target ("host{0}" -f $n) -Marker ("m{0}" -f $n) -WindowHandle ("0x{0:X}" -f $n) | Out-Null
                } -ArgumentList $localHelperPath, $stateDir, $i
            }

            Wait-Job -Job $jobs | Out-Null
            $jobs | Receive-Job | Out-Null
        } finally {
            if ($jobs.Count -gt 0) {
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            }
        }

        $sessionDir = Join-Path $stateDir "ClaudeSshImagePaste\sessions"
        $sessionFiles = @((Get-ChildItem -Path $sessionDir -Filter "*.json" -File -ErrorAction SilentlyContinue))
        if ($sessionFiles.Count -ne 8) {
            throw "Expected 8 concurrent sessions to be preserved, got $($sessionFiles.Count)."
        }
    } finally {
        $env:LOCALAPPDATA = $originalLocalAppData
        if ($localHelperPath) {
            $localHelperDir = Split-Path -Parent $localHelperPath
            if (Test-Path $localHelperDir) {
                Remove-Item -Path $localHelperDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path $stateDir) {
            Remove-Item -Path $stateDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-DefaultMarkerSessionPersistence([string]$HelperPath) {
    $originalLocalAppData = $env:LOCALAPPDATA
    $stateDir = Join-Path $env:TEMP ("csship-default-marker-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $localHelperPath = $null

    try {
        $env:LOCALAPPDATA = $stateDir
        $localHelperPath = New-LocalHelperCopy -SourceHelperPath $HelperPath

        Invoke-Helper $localHelperPath @("set-session", "-Target", "user@host", "-WindowHandle", "0x12345") | Out-Null
        $status = Invoke-Helper $localHelperPath @("status")
        if ($status -notmatch "Active:\s+1") {
            throw "Expected default-marker session to persist and be visible in status output.`n$status"
        }
    } finally {
        $env:LOCALAPPDATA = $originalLocalAppData
        if ($localHelperPath) {
            $localHelperDir = Split-Path -Parent $localHelperPath
            if (Test-Path $localHelperDir) {
                Remove-Item -Path $localHelperDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path $stateDir) {
            Remove-Item -Path $stateDir -Recurse -Force -ErrorAction SilentlyContinue
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
Test-ReservationLocking -HelperPath (Join-Path $BinDir "ClaudeSshImagePaste.ps1")
Test-SessionStateLocking -HelperPath (Join-Path $BinDir "ClaudeSshImagePaste.ps1")
Test-DefaultMarkerSessionPersistence -HelperPath (Join-Path $BinDir "ClaudeSshImagePaste.ps1")

Write-Host "Smoke test passed" -ForegroundColor Green
