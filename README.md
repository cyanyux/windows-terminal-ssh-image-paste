# windows-terminal-ssh-image-paste

Windows-side image paste bridge for SSH sessions in Windows Terminal.

It is designed for terminal-first tools such as Claude Code and Codex CLI running on a remote Linux host. When you press `Ctrl+V` inside a `cssh` session, the tool:

1. Reserves a short remote image path like `/tmp/i/1.png`
2. Inserts that path into the current terminal tab immediately
3. Uploads the clipboard image to the remote host in the background
4. Temporarily blocks `Enter` while the upload is in flight, so the CLI does not read the path before the file exists

The goal is not native GUI image attachments. The goal is reliable terminal workflow over SSH.

## What You Get

- Immediate path insertion in the current tab
- Background upload to the SSH target
- Very short remote paths: `/tmp/i/1.png`, `/tmp/i/2.png`, ...
- Session scoping by the actual Windows Terminal window handle
- PowerShell helpers for `cssh`, `cssh-status`, `cssh-on`, and `cssh-off`
- AutoHotkey startup integration

## Requirements

- Windows 10/11
- Windows Terminal
- PowerShell 5.1+ or PowerShell 7+
- `ssh.exe` and `scp.exe` available on Windows
- AutoHotkey v2
- Passwordless SSH access to the remote host recommended

## Install

Run from PowerShell on Windows:

```powershell
git clone https://github.com/cyanyux/windows-terminal-ssh-image-paste.git
cd windows-terminal-ssh-image-paste
.\scripts\install.ps1
```

If AutoHotkey v2 is not installed:

```powershell
.\scripts\install.ps1 -InstallAutoHotkey
```

The installer will:

- copy the scripts to `%USERPROFILE%\bin`
- add a managed block to both PowerShell profiles
- create a Startup entry for the AutoHotkey script
- start or restart the AutoHotkey watcher

## Quick Start

Open a new PowerShell tab in Windows Terminal, then:

```powershell
cssh user@host
```

Inside that SSH session:

1. copy an image to the Windows clipboard
2. press `Ctrl+V`
3. wait briefly before pressing `Enter`

If you are already inside an SSH tab and want to bind it manually:

```powershell
cssh-on -Target user@host
cssh-status
cssh-off
```

## Commands

```powershell
cssh user@host
cssh-status
cssh-on -Target user@host -WindowHandle 0x12345
cssh-off -Marker __CSSH__:...
```

`cssh` is the normal entrypoint. It wraps `ssh.exe`, binds the current Windows Terminal window to the SSH target, and clears the binding when the SSH process exits.

## Uninstall

From the repo:

```powershell
.\scripts\uninstall.ps1
```

This removes:

- `%USERPROFILE%\bin\ClaudeSsh.ps1`
- `%USERPROFILE%\bin\ClaudeSshImagePaste.ps1`
- `%USERPROFILE%\bin\ClaudeSshImagePaste.ahk`
- the Startup entry
- the managed PowerShell profile block

To also remove local runtime state and caches:

```powershell
.\scripts\uninstall.ps1 -RemoveState
```

## Smoke Test

```powershell
.\scripts\smoke-test.ps1
```

This checks:

- PowerShell syntax for the bundled scripts
- AutoHotkey availability and hotkey script loadability
- presence of the expected installation/runtime prerequisites

## Repository Layout

```text
bin/
  ClaudeSsh.ps1
  ClaudeSshImagePaste.ps1
  ClaudeSshImagePaste.ahk
scripts/
  install.ps1
  uninstall.ps1
  smoke-test.ps1
```

## Known Limits

- This is for terminal workflows, not GUI attachment chips.
- The remote path is inserted before upload completes, so `Enter` is blocked during upload.
- Session binding is scoped to a Windows Terminal window. If you manually reuse the same window for unrelated SSH flows, use `cssh` instead of `ssh` so the binding is refreshed correctly.

## License

MIT
