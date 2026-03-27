param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SshArgs
)

$ErrorActionPreference = "Stop"

$helper = Join-Path $PSScriptRoot "ClaudeSshImagePaste.ps1"
$originalTitle = $Host.UI.RawUI.WindowTitle
$windowHandle = ""

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ForegroundWindow {
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
}
'@

$SshOptionArgs = @(
    "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
    "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"
)

function Get-SshTargetFromArgs {
    param([string[]]$ArgsList)

    if (-not $ArgsList) {
        return $null
    }

    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        $arg = $ArgsList[$i]
        if (-not $arg) {
            continue
        }

        if ($arg -eq "--") {
            if ($i + 1 -lt $ArgsList.Count) {
                return $ArgsList[$i + 1]
            }
            break
        }

        if ($arg.StartsWith("-")) {
            if ($arg.Length -eq 2 -and $SshOptionArgs -contains $arg) {
                $i++
            }
            continue
        }

        return $arg
    }

    return $null
}

if (-not $SshArgs -or $SshArgs.Count -eq 0) {
    Write-Error "Usage: cssh <ssh arguments>"
    return
}

$target = Get-SshTargetFromArgs -ArgsList $SshArgs
if ([string]::IsNullOrWhiteSpace($target)) {
    Write-Error "Could not infer SSH target from arguments. Use a normal host form such as 'cssh nvidia' or 'cssh user@host'."
    return
}

$marker = "__CSSH__:{0}" -f ([guid]::NewGuid().ToString("N"))
$Host.UI.RawUI.WindowTitle = ("cssh {0} [{1}]" -f $target, $marker)
$windowHandle = ([ForegroundWindow]::GetForegroundWindow()).ToString()

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $helper set-session -Target $target -Marker $marker -WindowHandle $windowHandle | Out-Null

try {
    & ssh.exe @SshArgs
    $global:LASTEXITCODE = $LASTEXITCODE
} finally {
    $Host.UI.RawUI.WindowTitle = $originalTitle
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $helper clear-session -Marker $marker | Out-Null
}
