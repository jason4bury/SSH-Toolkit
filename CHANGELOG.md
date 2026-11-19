# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release folder names.

## [Unreleased]

## [1.02] - 2026-11-19

### Added
- **Changed identity check.** Before Open terminal, a double-click on a machine, Restart, and Key
  helper step 2 open a window, the toolkit quietly checks that the machine's identity (host key)
  still matches the one this PC remembers. If it has changed (for example after a reinstall), it
  shows the new fingerprint, the command to check it on the machine itself, and a **Forget old
  identity** button, instead of opening a window full of ssh's "REMOTE HOST IDENTIFICATION HAS
  CHANGED" warning. Commands run inside the window already offered this.

## [1.01] - 2026-11-19

### Added
- Get a file from it now opens a file browser for the machine: folders first, then files with size and date; Up, Home and a path box; Show hidden files; pick one or more files and click Get, then choose the folder on this PC. Folders load in the background, and a machine that doesn't answer shows a plain message in the browser.
- Light and dark themes: a Theme button (bottom right) switches between Follow Windows (the default), Dark and Light; the choice is saved in settings.json and every window follows it.
- Help button (bottom right, or F1) with short help on getting started, the SSH key setup, every button, what to do when something goes wrong, and where settings live.

### Changed
- The example compose project name in the README and the Edit window is now `myapp`.

## [1.00] - 2026-11-18
First release.

### Added
- Saved machines (name, address, port, user, compose folder and compose project) with Add, Edit and Remove, kept in `%APPDATA%\SSH Toolkit\settings.json`.
- A green or red dot for each machine: its SSH port is checked when the window opens, every minute and on Check now (no sign-in).
- Open terminal (or double-click a machine) for an SSH session in a terminal window.
- Quick commands: Disk space, Uptime and Docker ps shown in the window, and Restart machine (asks first, then a terminal for the sudo password).
- Docker Compose Pull, Up and Down in the machine's compose folder, with its project name. Down asks first.
- Send files to a machine and get a file from it (scp, with a fallback for machines without SFTP).
- SSH key helper: the make-a-key and copy-the-key commands in read-only boxes with Copy and Run it buttons.
- A box to run any other command, output that appears as it arrives, a Stop button and time limits.
- Plain-English messages for the usual SSH failures, and a button to forget a machine's old identity after a reinstall or a reused VM address.
- The app's own dialogs throughout (no Windows message boxes), in a dark look with dark title bars.
- No exe: `SSH Toolkit.cmd` and `New-SSHToolkitShortcut.ps1` make a shortcut and Start menu entry, and Build.cmd makes `Builds\SSH Toolkit.lnk` for the Home Launcher.
