param(
    [Parameter(Position = 0)]
    [ValidateSet("set-session", "clear-session", "status", "paste-image", "prepare-image", "upload-image", "reserve-path")]
    [string]$Command = "status",

    [string]$Target,
    [string]$Marker,
    [string]$Hash,
    [string]$WindowHandle,
    [string]$RemoteDir = "/tmp/i"
)

$ErrorActionPreference = "Stop"

$StateDir = Join-Path $env:LOCALAPPDATA "ClaudeSshImagePaste"
$SessionPath = Join-Path $StateDir "session.json"
$SessionDir = Join-Path $StateDir "sessions"
$LogPath = Join-Path $StateDir "paste.log"
$ImageDir = Join-Path $StateDir "images"
$UploadCacheDir = Join-Path $StateDir "upload-cache"
$RemoteReadyDir = Join-Path $StateDir "remote-ready"
$RemoteNameDir = Join-Path $StateDir "remote-names"
$PendingDir = Join-Path $StateDir "pending"
$LockDir = Join-Path $StateDir "locks"

function Ensure-StateDir {
    foreach ($dir in @($StateDir, $SessionDir, $ImageDir, $UploadCacheDir, $RemoteReadyDir, $RemoteNameDir, $PendingDir, $LockDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Get-DefaultRemoteDir {
    return "/tmp/i"
}

function Write-Log {
    param([string]$Message)

    try {
        Ensure-StateDir
        Add-Content -Path $LogPath -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message) -ErrorAction Stop
    } catch {
        # Best-effort logging only; operational paths should keep working even if
        # multiple helper processes race on the log file.
    }
}

function Normalize-WindowHandle {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $trimmed = $Value.Trim()
    try {
        if ($trimmed.StartsWith("0x", [System.StringComparison]::OrdinalIgnoreCase)) {
            $numeric = [Convert]::ToInt64($trimmed.Substring(2), 16)
            return ("0x{0:X}" -f $numeric)
        }

        $numeric = [Convert]::ToInt64($trimmed, 10)
        return ("0x{0:X}" -f $numeric)
    } catch {
        return $trimmed
    }
}

function Get-DefaultState {
    [ordered]@{
        version  = 2
        sessions = @()
    }
}

function New-SessionEntry {
    param(
        [string]$ResolvedTarget,
        [string]$ResolvedMarker,
        [string]$ResolvedWindowHandle,
        [string]$ResolvedRemoteDir
    )

    [pscustomobject]@{
        target       = $ResolvedTarget
        marker       = $ResolvedMarker
        windowHandle = Normalize-WindowHandle -Value $ResolvedWindowHandle
        remoteDir    = $ResolvedRemoteDir
        updatedAt    = (Get-Date).ToString("o")
    }
}

function Get-SessionFilePath {
    param([string]$ResolvedMarker)

    if ([string]::IsNullOrWhiteSpace($ResolvedMarker)) {
        throw "Marker is required."
    }

    Ensure-StateDir
    $safeMarker = ($ResolvedMarker -replace '[<>:"/\\|?*]', '_')
    return (Join-Path $SessionDir ("{0}.json" -f $safeMarker))
}

function Get-SessionFileEntries {
    Ensure-StateDir
    $entries = @()

    foreach ($file in @(Get-ChildItem -Path $SessionDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $raw = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($raw.target) -or [string]::IsNullOrWhiteSpace($raw.marker)) {
                continue
            }

            $entries += [pscustomobject]@{
                path    = $file.FullName
                session = (New-SessionEntry -ResolvedTarget $raw.target -ResolvedMarker $raw.marker -ResolvedWindowHandle $raw.windowHandle -ResolvedRemoteDir $(if ([string]::IsNullOrWhiteSpace($raw.remoteDir)) { Get-DefaultRemoteDir } else { $raw.remoteDir }))
            }
        } catch {
            Write-Log ("Ignoring invalid session file {0}: {1}" -f $file.FullName, $_.Exception.Message)
        }
    }

    return $entries
}

function Convert-LegacySessionToState {
    param([psobject]$Raw)

    $state = Get-DefaultState
    if (
        $null -ne $Raw -and
        $Raw.PSObject.Properties.Name -contains "enabled" -and
        $Raw.enabled -and
        -not [string]::IsNullOrWhiteSpace($Raw.target) -and
        -not [string]::IsNullOrWhiteSpace($Raw.marker)
    ) {
        $state.sessions = @(
            New-SessionEntry -ResolvedTarget $Raw.target -ResolvedMarker $Raw.marker -ResolvedWindowHandle $Raw.windowHandle -ResolvedRemoteDir $(if ([string]::IsNullOrWhiteSpace($Raw.remoteDir)) { Get-DefaultRemoteDir } else { $Raw.remoteDir })
        )
    }
    return $state
}

function Normalize-State {
    param([psobject]$Raw)

    $state = Get-DefaultState
    if ($null -eq $Raw) {
        return [pscustomobject]$state
    }

    if ($Raw.PSObject.Properties.Name -contains "sessions") {
        $sessions = @()
        foreach ($entry in @($Raw.sessions)) {
            if ($null -eq $entry) {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($entry.target) -or [string]::IsNullOrWhiteSpace($entry.marker)) {
                continue
            }

            $sessions += New-SessionEntry -ResolvedTarget $entry.target -ResolvedMarker $entry.marker -ResolvedWindowHandle $entry.windowHandle -ResolvedRemoteDir $(if ([string]::IsNullOrWhiteSpace($entry.remoteDir)) { Get-DefaultRemoteDir } else { $entry.remoteDir })
        }
        $state.sessions = $sessions
        return [pscustomobject]$state
    }

    if ($Raw.PSObject.Properties.Name -contains "enabled") {
        return [pscustomobject](Convert-LegacySessionToState -Raw $Raw)
    }

    return [pscustomobject]$state
}

function Get-State {
    $entries = @(Get-SessionFileEntries)
    if ($entries.Count -gt 0) {
        return [pscustomobject]@{
            version  = 2
            sessions = @($entries | ForEach-Object { $_.session })
        }
    }

    if (-not (Test-Path $SessionPath)) {
        return [pscustomobject](Get-DefaultState)
    }

    try {
        $raw = Get-Content -Path $SessionPath -Raw | ConvertFrom-Json
        return (Normalize-State -Raw $raw)
    } catch {
        Write-Log ("Session parse failed, resetting: {0}" -f $_.Exception.Message)
        return [pscustomobject](Get-DefaultState)
    }
}

function Get-Sessions {
    param([psobject]$State)

    if ($null -eq $State -or $null -eq $State.sessions) {
        return @()
    }
    return @($State.sessions)
}

function Get-SessionByMarker {
    param(
        [psobject]$State,
        [string]$ResolvedMarker
    )

    foreach ($session in @(Get-Sessions -State $State)) {
        if ($session.marker -eq $ResolvedMarker) {
            return $session
        }
    }

    return $null
}

function Get-SessionByWindowHandle {
    param(
        [psobject]$State,
        [string]$ResolvedWindowHandle
    )

    $normalizedWindowHandle = Normalize-WindowHandle -Value $ResolvedWindowHandle
    if ([string]::IsNullOrWhiteSpace($normalizedWindowHandle)) {
        return $null
    }

    $sessions = @(
        @(Get-Sessions -State $State) |
            Where-Object { (Normalize-WindowHandle -Value $_.windowHandle) -eq $normalizedWindowHandle } |
            Sort-Object updatedAt -Descending
    )

    foreach ($session in $sessions) {
        if ((Normalize-WindowHandle -Value $session.windowHandle) -eq $normalizedWindowHandle) {
            return $session
        }
    }

    return $null
}

function Get-PreferredSession {
    param([psobject]$State)

    $sessions = @(Get-Sessions -State $State)
    if ($sessions.Count -eq 1) {
        return $sessions[0]
    }
    if ($sessions.Count -eq 0) {
        return $null
    }

    $targets = @($sessions | ForEach-Object { $_.target } | Sort-Object -Unique)
    if ($targets.Count -eq 1) {
        return @($sessions | Sort-Object updatedAt -Descending)[0]
    }

    return $null
}

function Upsert-Session {
    param(
        [psobject]$State,
        [psobject]$Session
    )

    $sessions = @()
    foreach ($existing in @(Get-Sessions -State $State)) {
        $sameMarker = $existing.marker -eq $Session.marker
        $sameWindowHandle =
            -not [string]::IsNullOrWhiteSpace($existing.windowHandle) -and
            -not [string]::IsNullOrWhiteSpace($Session.windowHandle) -and
            (Normalize-WindowHandle -Value $existing.windowHandle) -eq (Normalize-WindowHandle -Value $Session.windowHandle)

        if (-not $sameMarker -and -not $sameWindowHandle) {
            $sessions += $existing
        }
    }
    $sessions += $Session

    return [pscustomobject]@{
        version  = 2
        sessions = $sessions
    }
}

function Remove-Session {
    param(
        [psobject]$State,
        [string]$ResolvedMarker
    )

    if ([string]::IsNullOrWhiteSpace($ResolvedMarker)) {
        return [pscustomobject](Get-DefaultState)
    }

    $sessions = @()
    foreach ($existing in @(Get-Sessions -State $State)) {
        if ($existing.marker -ne $ResolvedMarker) {
            $sessions += $existing
        }
    }

    return [pscustomobject]@{
        version  = 2
        sessions = $sessions
    }
}

function Get-ClipboardPngBytes {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
            $img = [System.Windows.Forms.Clipboard]::GetImage()
            if ($null -ne $img) {
                try {
                    $ms = New-Object System.IO.MemoryStream
                    try {
                        $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                        return $ms.ToArray()
                    } finally {
                        $ms.Dispose()
                    }
                } finally {
                    $img.Dispose()
                }
            }
        }

        Start-Sleep -Milliseconds 100
    }

    return $null
}

function Get-HashHex {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-StringHashHex {
    param([string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-RemoteCacheKey {
    param(
        [string]$ResolvedTarget,
        [string]$ResolvedRemoteDir
    )

    return Get-StringHashHex -Value ("{0}|{1}" -f $ResolvedTarget, $ResolvedRemoteDir.TrimEnd("/"))
}

function Get-UploadCachePath {
    param(
        [string]$CacheKey,
        [string]$Hash
    )

    return (Join-Path $UploadCacheDir ("{0}-{1}.txt" -f $CacheKey, $Hash))
}

function Get-PendingPath {
    param(
        [string]$CacheKey,
        [string]$Hash
    )

    return (Join-Path $PendingDir ("{0}-{1}.txt" -f $CacheKey, $Hash))
}

function Invoke-WithFileLock {
    param(
        [string]$LockName,
        [scriptblock]$ScriptBlock
    )

    Ensure-StateDir
    $mutexNameHash = Get-StringHashHex -Value ("{0}|{1}" -f $StateDir, $LockName)
    $mutexName = "Global\ClaudeSshImagePaste-{0}" -f $mutexNameHash.Substring(0, 32)
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $lockTaken = $false

    try {
        try {
            $lockTaken = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
    } catch {
        $mutex.Dispose()
        throw
    }

    if (-not $lockTaken) {
        $mutex.Dispose()
        throw "Timed out acquiring lock '$LockName'."
    }

    try {
        return (& $ScriptBlock)
    } finally {
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-RemoteFileName {
    param([string]$CacheKey)

    Ensure-StateDir
    $counterPath = Join-Path $RemoteNameDir ("{0}.txt" -f $CacheKey)
    $nextValue = 1

    if (Test-Path $counterPath) {
        try {
            $rawValue = (Get-Content -Path $counterPath -Raw).Trim()
            if ($rawValue -match '^\d+$') {
                $nextValue = [int]$rawValue
            }
        } catch {
        }
    }

    Set-Content -Path $counterPath -Value ([string]($nextValue + 1)) -Encoding UTF8
    return ("{0}.png" -f $nextValue)
}

function Resolve-SessionContext {
    param(
        [string]$ResolvedTarget,
        [string]$ResolvedMarker,
        [string]$ResolvedWindowHandle,
        [string]$ResolvedRemoteDir,
        [bool]$AllowTargetFallback = $true
    )

    $state = Get-State
    $session = $null
    if (-not [string]::IsNullOrWhiteSpace($ResolvedMarker)) {
        $session = Get-SessionByMarker -State $state -ResolvedMarker $ResolvedMarker
        if ($null -eq $session -and [string]::IsNullOrWhiteSpace($ResolvedTarget)) {
            throw "No active Claude SSH image-paste session for marker $ResolvedMarker."
        }
    }

    if ($null -eq $session -and -not [string]::IsNullOrWhiteSpace($ResolvedWindowHandle)) {
        $session = Get-SessionByWindowHandle -State $state -ResolvedWindowHandle $ResolvedWindowHandle
        if ($null -eq $session -and [string]::IsNullOrWhiteSpace($ResolvedTarget) -and [string]::IsNullOrWhiteSpace($ResolvedMarker)) {
            throw "No active Claude SSH image-paste session for window handle $ResolvedWindowHandle."
        }
    }

    if ($null -eq $session -and $AllowTargetFallback -and [string]::IsNullOrWhiteSpace($ResolvedTarget)) {
        $session = Get-PreferredSession -State $state
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedTarget)) {
        if ($null -eq $session -or [string]::IsNullOrWhiteSpace($session.target)) {
            throw "No active Claude SSH image-paste session."
        }
        $ResolvedTarget = $session.target
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedRemoteDir) -or $PSBoundParameters.ContainsKey("ResolvedRemoteDir") -eq $false) {
        if ($null -ne $session -and -not [string]::IsNullOrWhiteSpace($session.remoteDir)) {
            $ResolvedRemoteDir = $session.remoteDir
        } else {
            $ResolvedRemoteDir = Get-DefaultRemoteDir
        }
    }

    return [pscustomobject]@{
        target    = $ResolvedTarget
        remoteDir = $ResolvedRemoteDir
        session   = $session
    }
}

function Prepare-ClipboardImage {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $png = Get-ClipboardPngBytes
    if ($null -eq $png -or $png.Length -eq 0) {
        throw "Clipboard does not contain an image."
    }

    Ensure-StateDir
    $hash = Get-HashHex -Bytes $png
    $localPath = Join-Path $ImageDir ("{0}.png" -f $hash)
    if (-not (Test-Path $localPath)) {
        [System.IO.File]::WriteAllBytes($localPath, $png)
    }

    return [pscustomobject]@{
        hash      = $hash
        localPath = $localPath
    }
}

function Get-PreparedLocalPath {
    param([string]$PreparedHash)

    if ([string]::IsNullOrWhiteSpace($PreparedHash)) {
        throw "Hash is required."
    }

    $localPath = Join-Path $ImageDir ("{0}.png" -f $PreparedHash)
    if (-not (Test-Path $localPath)) {
        throw "Prepared image not found for hash $PreparedHash."
    }

    return $localPath
}

function Resolve-OrReserveRemotePath {
    param(
        [string]$ResolvedTarget,
        [string]$ResolvedRemoteDir,
        [string]$Hash
    )

    Ensure-StateDir
    $cacheKey = Get-RemoteCacheKey -ResolvedTarget $ResolvedTarget -ResolvedRemoteDir $ResolvedRemoteDir
    return Invoke-WithFileLock -LockName ("reserve-{0}" -f $cacheKey) -ScriptBlock {
        $cachePath = Get-UploadCachePath -CacheKey $cacheKey -Hash $Hash
        if (Test-Path $cachePath) {
            $cachedRemotePath = (Get-Content -Path $cachePath -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($cachedRemotePath)) {
                return [pscustomobject]@{
                    state      = "ready"
                    cacheKey   = $cacheKey
                    remotePath = $cachedRemotePath
                    cachePath  = $cachePath
                }
            }
        }

        $pendingPath = Get-PendingPath -CacheKey $cacheKey -Hash $Hash
        if (Test-Path $pendingPath) {
            $pendingRemotePath = (Get-Content -Path $pendingPath -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($pendingRemotePath)) {
                return [pscustomobject]@{
                    state       = "pending"
                    cacheKey    = $cacheKey
                    remotePath  = $pendingRemotePath
                    cachePath   = $cachePath
                    pendingPath = $pendingPath
                }
            }
        }

        $remotePath = ("{0}/{1}" -f $ResolvedRemoteDir.TrimEnd("/"), (Get-RemoteFileName -CacheKey $cacheKey))
        Set-Content -Path $pendingPath -Value $remotePath -Encoding UTF8
        return [pscustomobject]@{
            state       = "pending"
            cacheKey    = $cacheKey
            remotePath  = $remotePath
            cachePath   = $cachePath
            pendingPath = $pendingPath
        }
    }
}

function Quote-RemoteShellLiteral {
    param([string]$Value)

    $replacement = "'" + '"' + "'" + '"' + "'"
    return "'" + $Value.Replace("'", $replacement) + "'"
}

function Invoke-RemoteUpload {
    param(
        [string]$ResolvedTarget,
        [string]$ResolvedRemoteDir,
        [string]$LocalPath,
        [string]$Hash
    )

    $reservation = Resolve-OrReserveRemotePath -ResolvedTarget $ResolvedTarget -ResolvedRemoteDir $ResolvedRemoteDir -Hash $Hash
    if ($reservation.state -eq "ready") {
        return $reservation.remotePath
    }

    $cacheKey = $reservation.cacheKey
    $cachePath = $reservation.cachePath
    $pendingPath = $reservation.pendingPath
    $remotePath = $reservation.remotePath
    $quotedRemoteDir = Quote-RemoteShellLiteral -Value $ResolvedRemoteDir

    $readyPath = Join-Path $RemoteReadyDir ("{0}.ready" -f $cacheKey)
    if (-not (Test-Path $readyPath)) {
        & ssh.exe -o BatchMode=yes $ResolvedTarget "mkdir -p $quotedRemoteDir" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "ssh mkdir failed for ${ResolvedTarget}:$ResolvedRemoteDir"
        }
        Set-Content -Path $readyPath -Value $ResolvedRemoteDir -Encoding UTF8
    }

    & scp.exe -q -o BatchMode=yes $LocalPath ("{0}:{1}" -f $ResolvedTarget, $remotePath)
    if ($LASTEXITCODE -ne 0) {
        try { Remove-Item -Path $readyPath -Force -ErrorAction SilentlyContinue } catch {}

        & ssh.exe -o BatchMode=yes $ResolvedTarget "mkdir -p $quotedRemoteDir" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "ssh mkdir retry failed for ${ResolvedTarget}:$ResolvedRemoteDir"
        }
        Set-Content -Path $readyPath -Value $ResolvedRemoteDir -Encoding UTF8

        & scp.exe -q -o BatchMode=yes $LocalPath ("{0}:{1}" -f $ResolvedTarget, $remotePath)
        if ($LASTEXITCODE -ne 0) {
            throw "scp upload failed for ${ResolvedTarget}:$remotePath"
        }
    }

    Invoke-WithFileLock -LockName ("reserve-{0}" -f $cacheKey) -ScriptBlock {
        Set-Content -Path $cachePath -Value $remotePath -Encoding UTF8
        if ($pendingPath) {
            try { Remove-Item -Path $pendingPath -Force -ErrorAction SilentlyContinue } catch {}
        }
    } | Out-Null
    return $remotePath
}

switch ($Command) {
    "set-session" {
        if ([string]::IsNullOrWhiteSpace($Target)) {
            throw "Target is required."
        }

        $resolvedMarker = $Marker
        if ([string]::IsNullOrWhiteSpace($resolvedMarker)) {
            $resolvedMarker = "__CSSH__:{0}" -f ([guid]::NewGuid().ToString("N"))
        }

        $session = New-SessionEntry -ResolvedTarget $Target -ResolvedMarker $resolvedMarker -ResolvedWindowHandle $WindowHandle -ResolvedRemoteDir $RemoteDir
        $sessionFilePath = Get-SessionFilePath -ResolvedMarker $resolvedMarker
        $session | ConvertTo-Json -Depth 5 | Set-Content -Path $sessionFilePath -Encoding UTF8
        Remove-Item -Path $SessionPath -Force -ErrorAction SilentlyContinue

        foreach ($entry in @(Get-SessionFileEntries)) {
            if ($entry.session.marker -eq $resolvedMarker) {
                continue
            }

            $sameWindowHandle =
                -not [string]::IsNullOrWhiteSpace($entry.session.windowHandle) -and
                -not [string]::IsNullOrWhiteSpace($session.windowHandle) -and
                (Normalize-WindowHandle -Value $entry.session.windowHandle) -eq (Normalize-WindowHandle -Value $session.windowHandle)

            if ($sameWindowHandle) {
                Remove-Item -Path $entry.path -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Log ("Enabled session {0} -> {1} (hwnd={2})" -f $resolvedMarker, $Target, $(if ([string]::IsNullOrWhiteSpace($WindowHandle)) { "(unset)" } else { $WindowHandle }))
        Write-Output ("Enabled session for {0} ({1})" -f $Target, $resolvedMarker)
    }

    "clear-session" {
        if ([string]::IsNullOrWhiteSpace($Marker)) {
            Get-ChildItem -Path $SessionDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $SessionPath -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared all sessions."
            Write-Output "Cleared all sessions."
        } else {
            $sessionFilePath = Get-SessionFilePath -ResolvedMarker $Marker
            Remove-Item -Path $sessionFilePath -Force -ErrorAction SilentlyContinue
            Write-Log ("Cleared session {0}" -f $Marker)
            Write-Output ("Cleared session {0}." -f $Marker)
        }
    }

    "status" {
        $state = Get-State
        $sessions = @(Get-Sessions -State $state)
        Write-Output ("Active:       {0}" -f $sessions.Count)
        foreach ($session in $sessions | Sort-Object marker) {
            Write-Output ("Session:      {0} => {1} ({2})" -f $session.marker, $session.target, $session.remoteDir)
            Write-Output ("Window:       {0}" -f ($(if ($session.windowHandle) { $session.windowHandle } else { "(unset)" })))
        }
        Write-Output ("Session dir:  {0}" -f $SessionDir)
        if (Test-Path $SessionPath) {
            Write-Output ("Legacy file:  {0}" -f $SessionPath)
        }
        Write-Output ("Log file:     {0}" -f $LogPath)
    }

    "paste-image" {
        $context = Resolve-SessionContext -ResolvedTarget $Target -ResolvedMarker $Marker -ResolvedWindowHandle $WindowHandle -ResolvedRemoteDir $RemoteDir
        $prepared = Prepare-ClipboardImage
        $remotePath = Invoke-RemoteUpload -ResolvedTarget $context.target -ResolvedRemoteDir $context.remoteDir -LocalPath $prepared.localPath -Hash $prepared.hash
        Write-Log ("Uploaded {0} -> {1}:{2}" -f $prepared.hash, $context.target, $remotePath)
        Write-Output $remotePath
    }

    "prepare-image" {
        $context = Resolve-SessionContext -ResolvedTarget $Target -ResolvedMarker $Marker -ResolvedWindowHandle $WindowHandle -ResolvedRemoteDir $RemoteDir
        $prepared = Prepare-ClipboardImage
        $reservation = Resolve-OrReserveRemotePath -ResolvedTarget $context.target -ResolvedRemoteDir $context.remoteDir -Hash $prepared.hash
        Write-Output ("{0}|{1}|{2}" -f $reservation.state.ToUpperInvariant(), $reservation.remotePath, $prepared.hash)
    }

    "upload-image" {
        if ([string]::IsNullOrWhiteSpace($Marker) -and [string]::IsNullOrWhiteSpace($WindowHandle) -and [string]::IsNullOrWhiteSpace($Target)) {
            throw "Marker, WindowHandle, or Target is required."
        }
        if ([string]::IsNullOrWhiteSpace($Hash)) {
            throw "Hash is required."
        }

        if ([string]::IsNullOrWhiteSpace($RemoteDir) -or $PSBoundParameters.ContainsKey("RemoteDir") -eq $false) {
            $RemoteDir = ""
        }

        $context = Resolve-SessionContext -ResolvedTarget $Target -ResolvedMarker $Marker -ResolvedWindowHandle $WindowHandle -ResolvedRemoteDir $RemoteDir
        $localPath = Get-PreparedLocalPath -PreparedHash $Hash
        $remotePath = Invoke-RemoteUpload -ResolvedTarget $context.target -ResolvedRemoteDir $context.remoteDir -LocalPath $localPath -Hash $Hash
        Write-Log ("Uploaded {0} -> {1}:{2}" -f $Hash, $context.target, $remotePath)
        Write-Output $remotePath
    }

    "reserve-path" {
        if ([string]::IsNullOrWhiteSpace($Hash)) {
            throw "Hash is required."
        }

        if ([string]::IsNullOrWhiteSpace($RemoteDir) -or $PSBoundParameters.ContainsKey("RemoteDir") -eq $false) {
            $RemoteDir = ""
        }

        $context = Resolve-SessionContext -ResolvedTarget $Target -ResolvedMarker $Marker -ResolvedWindowHandle $WindowHandle -ResolvedRemoteDir $RemoteDir
        $reservation = Resolve-OrReserveRemotePath -ResolvedTarget $context.target -ResolvedRemoteDir $context.remoteDir -Hash $Hash
        Write-Output ("{0}|{1}" -f $reservation.state.ToUpperInvariant(), $reservation.remotePath)
    }
}
