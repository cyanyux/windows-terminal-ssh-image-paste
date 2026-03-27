#Requires AutoHotkey v2.0
#SingleInstance Force

global PowerShellExe := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
global HelperScript := A_ScriptDir "\ClaudeSshImagePaste.ps1"
global StateDir := EnvGet("LOCALAPPDATA") "\ClaudeSshImagePaste"
global SessionDir := StateDir "\sessions"
global SessionPath := StateDir "\session.json"
global AhkLogPath := StateDir "\ahk.log"
global PasteInFlight := false
global ActiveUpload := 0

WriteDebugLog(message) {
    try {
        if !DirExist(StateDir) {
            DirCreate StateDir
        }
        FileAppend FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message "`n", AhkLogPath, "UTF-8"
    }
}

WriteDebugLog("script loaded | pid=" DllCall("GetCurrentProcessId") " | sessionDir=" SessionDir)

GetActiveClaudeSshMarker() {
    title := WinGetTitle("A")
    if RegExMatch(title, "(__CSSH__:[0-9a-f]{32})", &match) {
        return match[1]
    }
    return ""
}

GetActiveWindowHandle() {
    return Format("0x{:X}", WinGetID("A"))
}

HasBoundSession(windowHandle) {
    if (windowHandle = "") {
        return false
    }

    normalized := NormalizeWindowHandle(windowHandle)

    if DirExist(SessionDir) {
        Loop Files, SessionDir "\*.json", "F" {
            try {
                sessionJson := FileRead(A_LoopFileFullPath, "UTF-8")
            } catch {
                continue
            }

            if (RegExMatch(sessionJson, '"windowHandle"\s*:\s*"' normalized '"') > 0) {
                return true
            }
        }
    }

    if !FileExist(SessionPath) {
        return false
    }

    try {
        sessionJson := FileRead(SessionPath, "UTF-8")
    } catch {
        return false
    }

    return RegExMatch(sessionJson, '"windowHandle"\s*:\s*"' normalized '"') > 0
}

BuildHelperCommand(action, windowHandle, marker, extraArgs := "") {
    commandLine := '"' PowerShellExe '" -STA -WindowStyle Hidden -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' HelperScript '" ' action
    if (windowHandle != "") {
        commandLine .= ' -WindowHandle "' windowHandle '"'
    } else if (marker != "") {
        commandLine .= ' -Marker "' marker '"'
    }
    if (extraArgs != "") {
        commandLine .= extraArgs
    }
    return commandLine
}

NormalizeWindowHandle(windowHandle) {
    if (windowHandle = "") {
        return ""
    }

    normalized := Trim(windowHandle)
    if RegExMatch(normalized, "^0x[0-9A-Fa-f]+$") {
        return "0x" Format("{:X}", Integer(normalized))
    }

    if RegExMatch(normalized, "^\d+$") {
        return "0x" Format("{:X}", Integer(normalized))
    }

    return normalized
}

IsUploadBlockingWindow() {
    global PasteInFlight
    global ActiveUpload

    if (!PasteInFlight || !IsObject(ActiveUpload)) {
        return false
    }

    return NormalizeWindowHandle(GetActiveWindowHandle()) = NormalizeWindowHandle(ActiveUpload.WindowHandle)
}

PasteTextViaTerminal(windowHandle, text) {
    targetWindow := NormalizeWindowHandle(windowHandle)
    if (targetWindow != "") {
        targetSpec := "ahk_id " targetWindow
        if WinExist(targetSpec) {
            if NormalizeWindowHandle(GetActiveWindowHandle()) != targetWindow {
                WinActivate targetSpec
                try WinWaitActive targetSpec, , 0.5
            }
            if NormalizeWindowHandle(GetActiveWindowHandle()) != targetWindow {
                return false
            }
        }
    }

    SendText text
    return true
}

ExecCommandHidden(commandLine) {
    token := Format("{}-{}", A_TickCount, DllCall("GetCurrentProcessId"))
    stdoutPath := A_Temp "\claude-ssh-image-paste-" token ".out"
    stderrPath := A_Temp "\claude-ssh-image-paste-" token ".err"
    batchPath := A_Temp "\claude-ssh-image-paste-" token ".cmd"

    batch := "@echo off`r`n"
    batch .= commandLine ' 1>"' stdoutPath '" 2>"' stderrPath '"`r`n'
    batch .= "exit /b %errorlevel%`r`n"
    FileAppend batch, batchPath, "UTF-8-RAW"

    exitCode := RunWait('"' A_ComSpec '" /d /c ""' batchPath '""', , "Hide")
    stdout := FileExist(stdoutPath) ? FileRead(stdoutPath, "UTF-8") : ""
    stderr := FileExist(stderrPath) ? FileRead(stderrPath, "UTF-8") : ""

    try FileDelete(stdoutPath)
    try FileDelete(stderrPath)
    try FileDelete(batchPath)

    return {
        ExitCode: exitCode,
        StdOut: stdout,
        StdErr: stderr
    }
}

StartAsyncCommandHidden(commandLine, title, marker, windowHandle, remotePath, hash) {
    token := Format("{}-{}", A_TickCount, DllCall("GetCurrentProcessId"))
    stdoutPath := A_Temp "\claude-ssh-image-paste-" token ".out"
    stderrPath := A_Temp "\claude-ssh-image-paste-" token ".err"
    exitPath := A_Temp "\claude-ssh-image-paste-" token ".code"
    batchPath := A_Temp "\claude-ssh-image-paste-" token ".cmd"

    batch := "@echo off`r`n"
    batch .= commandLine ' 1>"' stdoutPath '" 2>"' stderrPath '"`r`n'
    batch .= '> "' exitPath '" echo %errorlevel%`r`n'
    FileAppend batch, batchPath, "UTF-8-RAW"

    pid := 0
    Run('"' A_ComSpec '" /d /c ""' batchPath '""', , "Hide", &pid)

    return {
        Pid: pid,
        StdOutPath: stdoutPath,
        StdErrPath: stderrPath,
        ExitPath: exitPath,
        BatchPath: batchPath,
        Title: title,
        Marker: marker,
        WindowHandle: windowHandle,
        RemotePath: remotePath,
        Hash: hash
    }
}

FinishAsyncCommand(task) {
    stdout := FileExist(task.StdOutPath) ? FileRead(task.StdOutPath, "UTF-8") : ""
    stderr := FileExist(task.StdErrPath) ? FileRead(task.StdErrPath, "UTF-8") : ""
    exitRaw := FileExist(task.ExitPath) ? Trim(FileRead(task.ExitPath, "UTF-8"), "`r`n ") : "1"
    exitCode := exitRaw + 0

    try FileDelete(task.StdOutPath)
    try FileDelete(task.StdErrPath)
    try FileDelete(task.ExitPath)
    try FileDelete(task.BatchPath)

    return {
        ExitCode: exitCode,
        StdOut: stdout,
        StdErr: stderr
    }
}

NotifyUploadFailure(task, stderrText) {
    summary := "Image upload failed for " task.RemotePath
    details := Trim(stderrText, "`r`n ")
    if (details != "") {
        summary .= "`n" details
    }

    SoundBeep 750, 120
    try TrayTip summary, "terminal-ssh-image-paste", 17
}

NotifyPasteFailure(reason) {
    SoundBeep 600, 120
    try TrayTip reason, "terminal-ssh-image-paste", 17
}

PollUpload(*) {
    global PasteInFlight
    global ActiveUpload

    if !IsObject(ActiveUpload) {
        SetTimer PollUpload, 0
        return
    }

    if !FileExist(ActiveUpload.ExitPath) {
        return
    }

    result := FinishAsyncCommand(ActiveUpload)
    if (result.ExitCode = 0) {
        WriteDebugLog("background upload complete | title=" ActiveUpload.Title " | marker=" ActiveUpload.Marker " | hwnd=" ActiveUpload.WindowHandle " | path=" ActiveUpload.RemotePath)
    } else {
        WriteDebugLog("background upload failed | title=" ActiveUpload.Title " | marker=" ActiveUpload.Marker " | hwnd=" ActiveUpload.WindowHandle " | exit=" result.ExitCode " | stderr=" Trim(result.StdErr, "`r`n"))
        NotifyUploadFailure(ActiveUpload, result.StdErr)
    }

    PasteInFlight := false
    ActiveUpload := 0
    SetTimer PollUpload, 0
}

#HotIf WinActive("ahk_exe WindowsTerminal.exe") && IsUploadBlockingWindow()
Enter::
{
    WriteDebugLog("blocked Enter while upload in flight")
}

NumpadEnter::
{
    WriteDebugLog("blocked NumpadEnter while upload in flight")
}
#HotIf

#HotIf WinActive("ahk_exe WindowsTerminal.exe")
$^v::
{
    global PasteInFlight
    global ActiveUpload

    if (PasteInFlight) {
        WriteDebugLog("ignored repeat hotkey while upload in flight")
        return
    }

    KeyWait "v"
    KeyWait "Ctrl"

    title := WinGetTitle("A")
    marker := GetActiveClaudeSshMarker()
    windowHandle := GetActiveWindowHandle()
    WriteDebugLog("hotkey hit | title=" title " | marker=" marker " | hwnd=" windowHandle)

    if !HasBoundSession(windowHandle) {
        WriteDebugLog("fallback native paste | title=" title " | marker=" marker " | hwnd=" windowHandle)
        Send "^v"
        return
    }

    try {
        prepareCommand := BuildHelperCommand("prepare-image", windowHandle, marker)
        result := ExecCommandHidden(prepareCommand)
        response := Trim(result.StdOut, "`r`n")

        if (result.ExitCode != 0 || response = "") {
            WriteDebugLog("prepare failed | title=" title " | marker=" marker " | hwnd=" windowHandle " | exit=" result.ExitCode " | stderr=" Trim(result.StdErr, "`r`n"))
            Send "^v"
            return
        }

        fields := StrSplit(response, "|")
        if (fields.Length < 3) {
            WriteDebugLog("prepare parse failed | title=" title " | marker=" marker " | hwnd=" windowHandle " | stdout=" response)
            Send "^v"
            return
        }

        state := fields[1]
        remotePath := fields[2]
        hash := fields[3]

        if !PasteTextViaTerminal(windowHandle, remotePath) {
            NotifyPasteFailure("Image paste cancelled because the target terminal is no longer focused.")
            WriteDebugLog("paste cancelled because target window was not active | title=" title " | marker=" marker " | hwnd=" windowHandle)
            return
        }
        WriteDebugLog("path inserted | title=" title " | marker=" marker " | hwnd=" windowHandle " | state=" state " | path=" remotePath)
    } catch as err {
        WriteDebugLog("paste dispatch failed | title=" title " | marker=" marker " | hwnd=" windowHandle " | error=" err.Message)
        NotifyPasteFailure("Image paste failed before the path could be inserted.")
        return
    }

    if (state = "READY") {
        return
    }

    uploadCommand := BuildHelperCommand("upload-image", windowHandle, marker, ' -Hash "' hash '"')
    ActiveUpload := StartAsyncCommandHidden(uploadCommand, title, marker, windowHandle, remotePath, hash)
    PasteInFlight := true
    SetTimer PollUpload, 200
}
#HotIf
