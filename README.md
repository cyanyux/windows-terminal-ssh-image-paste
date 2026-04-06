# Paste Images into SSH Sessions from Windows Terminal

**Ctrl+V clipboard images straight into Claude Code, Codex CLI, or any terminal tool running over SSH.**

Windows Terminal does not support pasting images into remote SSH sessions. This tool bridges that gap: it intercepts `Ctrl+V`, saves the clipboard image locally, uploads it to the remote host via `scp`, and inserts the remote file path into your terminal — all without leaving your current tab.

## The Problem

You are running Claude Code (or another AI coding assistant) on a remote Linux server via SSH. You want to paste a screenshot for context. You press `Ctrl+V` and… nothing useful happens. Windows Terminal has no way to send clipboard images over SSH.

## The Solution

`cssh` wraps your SSH connection and enables image pasting:

```
┌──────────────────────────────────────────────────────┐
│  Windows Terminal                                    │
│  ┌────────────────────────────────────────────────┐  │
│  │ $ cssh user@server                             │  │
│  │                                                │  │
│  │ claude> describe this UI bug                   │  │
│  │ claude> /tmp/i/1.png  ← Ctrl+V inserted this  │  │
│  │                                                │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
         │                              ▲
         │  scp (background upload)     │  ssh
         ▼                              │
   ┌───────────┐                 ┌─────────────┐
   │ /tmp/i/   │                 │ Claude Code  │
   │  1.png    │────────────────▶│ reads image  │
   └───────────┘  path ready     └─────────────┘
```

## How It Works

When you press `Ctrl+V` inside a `cssh` session with an image on the clipboard:

1. A short remote path is reserved (e.g., `/tmp/i/1.png`)
2. That path is typed into the terminal immediately
3. The image is uploaded to the remote host in the background via `scp`
4. `Enter` is temporarily blocked until the upload finishes, so the tool does not try to read the file before it exists

## Features

- **Same-tab SSH** — `cssh` runs in your current Windows Terminal tab, no new windows
- **Instant path insertion** — the path appears immediately, upload happens in the background
- **Short paths** — `/tmp/i/1.png`, `/tmp/i/2.png`, … easy to type or reference
- **Window-scoped sessions** — binding is tied to the Windows Terminal window handle
- **PowerShell helpers** — `cssh`, `cssh-status`, `cssh-on`, `cssh-off`
- **AutoHotkey integration** — a background watcher intercepts `Ctrl+V` only when a `cssh` session is active

## Requirements

- Windows 10 or 11
- [Windows Terminal](https://aka.ms/terminal)
- PowerShell 5.1+ or PowerShell 7+
- `ssh.exe` and `scp.exe` on PATH (included with Windows 10+)
- [AutoHotkey v2](https://www.autohotkey.com/)
- Passwordless SSH (key-based auth) recommended

## Install

Run from PowerShell on Windows:

```powershell
git clone https://github.com/cyanyux/windows-terminal-ssh-image-paste.git
cd windows-terminal-ssh-image-paste
.\scripts\install.ps1
```

To also install AutoHotkey v2 automatically:

```powershell
.\scripts\install.ps1 -InstallAutoHotkey
```

The installer:

- Copies scripts to `%USERPROFILE%\bin`
- Adds a managed block to your PowerShell profile
- Creates a Startup shortcut for the AutoHotkey watcher
- Starts the AutoHotkey watcher immediately

## Quick Start

1. Open a PowerShell tab in Windows Terminal
2. Connect with `cssh` instead of `ssh`:

   ```powershell
   cssh user@host
   ```

3. Copy an image to your Windows clipboard (screenshot, snip, etc.)
4. Press `Ctrl+V` — the remote path appears in the terminal
5. Wait briefly for the upload indicator, then press `Enter`

## Commands

| Command | Description |
|---------|-------------|
| `cssh user@host` | Connect via SSH with image paste enabled |
| `cssh-here user@host` | Explicit alias for same-tab behavior |
| `cssh-status` | Show the current session binding |
| `cssh-on -Target user@host` | Manually bind the current tab to a host |
| `cssh-off` | Clear the current session binding |

## Uninstall

```powershell
.\scripts\uninstall.ps1
```

To also remove local state and caches:

```powershell
.\scripts\uninstall.ps1 -RemoveState
```

## Smoke Test

```powershell
.\scripts\smoke-test.ps1
```

Checks PowerShell script syntax, AutoHotkey availability, and installation prerequisites.

## Project Layout

```
bin/
  ClaudeSsh.ps1               # SSH wrapper and session management
  ClaudeSshImagePaste.ps1     # Image capture, upload, and path logic
  ClaudeSshImagePaste.ahk     # AutoHotkey Ctrl+V interceptor
scripts/
  install.ps1                 # Installer
  uninstall.ps1               # Uninstaller
  smoke-test.ps1              # Verification script
```

## Known Limitations

- Designed for terminal-based workflows, not GUI image attachment UIs
- The remote path is inserted before the upload finishes — `Enter` is blocked during upload to prevent reading a missing file
- Session binding is per-window, not per-tab. Avoid switching tabs between copy and paste if the window also has local WSL tabs

## License

MIT
