# Vizier on Linux

Vizier 0.2.0 is the first release with Linux support. It runs the same take engine as the Mac app. Tested end to end on X11 and on headless Sway; see [What is not verified](#what-is-not-verified) for what has not met a real desktop.

## What it is

On Linux, Vizier is a background daemon plus the `vizier` command. There is no window, no tray icon and no settings screen. You press a hotkey, talk, press it again, and the text is pasted at the cursor. Feedback comes from desktop notifications and short sounds.

The daemon does the work. Every other command (`vizier toggle`, `vizier status`, `vizier last`) talks to it over a private socket in `$XDG_RUNTIME_DIR/vizier/`. [docs/cli.md](cli.md) has every command, exit code and JSON shape. Modes, vocabulary and replacements work as on the Mac; see [modes and configuration](modes-and-config.md).

## Requirements

- A microphone, and PipeWire or PulseAudio. Vizier records with `pw-record`, or `parec` if that is all you have. On Debian and Ubuntu: `sudo apt install pipewire-bin`.
- For the live cloud modes (Scribe, Gemini live), libcurl 8.11 or later. Debian 13 and Ubuntu 25.04 and later have it. On an older distro the batch engines still work and `vizier doctor` fails the `libcurl` check.
- One speech route:
  - **Local (the default mode, no keys).** A whisper.cpp server on this machine. See [Local mode](#local-mode).
  - **ElevenLabs or Gemini.** An API key, set with `vizier key set`. See [Cloud modes](#cloud-modes).
- Tools for pasting, depending on your desktop; see [How pasting works](#how-pasting-works).

## Install

The packages are for x86_64 (amd64) Linux. Download one from the [release page](https://github.com/treygoff24/vizier/releases/latest). For release 0.2.0 the files are:

- `vizier_0.2.0_amd64.deb`. Install it with `sudo apt install ./vizier_0.2.0_amd64.deb`. It installs `/usr/bin/vizier`, the sounds, the desktop entry and a systemd user unit, and pulls in the libraries it needs. The helper tools for audio, clipboard and pasting are recommended packages; see [Requirements](#requirements).
- `Vizier-0.2.0-x86_64.AppImage`. Make it executable (`chmod +x`) and keep it somewhere permanent. It takes the same arguments as the `vizier` command (`./Vizier-0.2.0-x86_64.AppImage setup`), and setup points the service and desktop entry at that path. It uses your system's libraries (libcurl, SQLite, libsystemd) instead of bundling them.

Later releases name their files the same way with their own version.

To build from source, install Swift 6.4 with [swiftly](https://www.swift.org/install/linux/), then:

```bash
swift build -c release --product vizier
```

The binary is `.build/release/vizier`. Put it on your `PATH`.

## First run

Open a terminal inside your desktop session, not over SSH and not from a bare login shell. Then run:

```bash
vizier setup
```

Setup looks at your desktop, microphone tool, paste tools, hotkey route, keys and local whisper server, and prints one line per check with a fix when something is missing. It also:

- writes a starter config to `~/.config/vizier/` if there is none,
- asks the GNOME and KDE portals for the consents a take should never wait on,
- writes `~/.config/systemd/user/vizier.service`,
- prints the compositor binds for your desktop.

Setup exits 5 if the desktop, capture or clipboard check fails. A `warn` means dictation still works but something is reduced, such as no paste keys (the text stays on the clipboard).

To start Vizier now and at every login, run `vizier setup --autostart`, or run `systemctl --user enable --now vizier.service` yourself. The unit starts `vizier daemon` with your graphical session and restarts it if it fails. If you skip this, run `vizier daemon` in a terminal.

`vizier setup --no-portal` skips the consent dialogs.

**The paste tools need your display variables.** The daemon finds `WAYLAND_DISPLAY`, `DISPLAY` and `XDG_CURRENT_DESKTOP` in its own environment, and the systemd user manager does not have your terminal's. `vizier setup --autostart` therefore imports, just before it enables the unit, the ones of these that are set in the shell you run it from: `WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`, `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `XDG_RUNTIME_DIR`, `XDG_DATA_DIRS`, `XDG_CONFIG_DIRS`, `SWAYSOCK`, `HYPRLAND_INSTANCE_SIGNATURE` and `DBUS_SESSION_BUS_ADDRESS`. Never the whole environment. Run it from a terminal inside your desktop session. If you enable the unit yourself, or the session changes, run this from your session's startup script:

```bash
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP
```

Then check with `vizier doctor`.

## Taking a dictation

1. Put the cursor where you want the text.
2. Press the hotkey. A notification says recording has started.
3. Talk.
4. Press the hotkey again. Vizier finishes the transcript and pastes it.

It is tap to start and tap to stop, as on the Mac. The cancel chord, or `vizier cancel`, drops a take that is recording or finishing; nothing is pasted.

## The hotkey

Vizier uses a chord, never a bare modifier key. Linux gives a background program no safe way to watch a lone modifier. There is also no Escape to cancel, unless you bind Escape yourself to `vizier cancel`.

**GNOME 48 or later, KDE and Hyprland: through the desktop portal.** The daemon asks the GlobalShortcuts portal for two shortcuts: **Ctrl+Alt+Space** toggles and **Ctrl+Alt+Backspace** cancels. The desktop may show a consent dialog the first time. The chord is a request: the desktop owns the final binding. To change it, use your desktop's keyboard shortcut settings, where the Vizier entries should appear. Which settings page shows them differs by desktop, and this has not been checked on a real one. If the portal is missing or refuses, setup reports the hotkey check as `warn`; use a bind from the next list.

**Sway, niri, river, labwc and other wlroots compositors, and GNOME before 48: a bind that runs `vizier toggle` and `vizier cancel`.** Setup prints the lines for your desktop. These are the ones it prints:

Sway, in `~/.config/sway/config`:

```text
bindsym Ctrl+Alt+space exec /path/to/vizier toggle
bindsym Ctrl+Alt+BackSpace exec /path/to/vizier cancel
```

Hyprland, in `~/.config/hypr/hyprland.conf`:

```text
bind = CTRL ALT, space, exec, /path/to/vizier toggle
bind = CTRL ALT, BackSpace, exec, /path/to/vizier cancel
```

niri, in `~/.config/niri/config.kdl`, inside `binds { }`:

```text
Ctrl+Alt+Space { spawn "/path/to/vizier" "toggle"; }
Ctrl+Alt+BackSpace { spawn "/path/to/vizier" "cancel"; }
```

GNOME: Settings › Keyboard › Keyboard Shortcuts › Custom Shortcuts. Add `vizier toggle` on Ctrl+Alt+Space and `vizier cancel` on Ctrl+Alt+Backspace.

KDE: System Settings › Keyboard › Shortcuts › Add Command. Same two commands and chords.

`/path/to/vizier` is the real path of the binary; setup prints it. Change the chords to whatever you like. They are only keys in your compositor's config. On a desktop setup does not recognise, it prints the lines for all of these.

## How pasting works

Vizier puts the text on the clipboard, checks that the clipboard still holds it, then sends the paste keys. It uses Ctrl+V, or Ctrl+Shift+V when the focused app is a known terminal (foot, kitty, alacritty, wezterm, GNOME Terminal, Konsole, xterm, ptyxis, ghostty and others). The text gets one trailing space. The clipboard is not restored afterwards.

| Desktop | Clipboard | Paste keys |
|---|---|---|
| GNOME, KDE (Wayland) | The RemoteDesktop portal | The RemoteDesktop portal. You approve a consent dialog once, in `vizier setup`; the grant is remembered. |
| Sway, niri, river, Hyprland and other wlroots (Wayland) | `wl-copy` (package `wl-clipboard`) | `wtype` |
| X11 | `xclip` or `xsel` | `xdotool` |
| Any, opt-in | | `ydotool`, tried last, only when `VIZIER_YDOTOOL=1` is set in the daemon's environment |

Install what your row names: for example `sudo apt install wl-clipboard wtype`, or `sudo apt install xclip xdotool`.

**ydotool** types through the kernel's uinput device. It needs `ydotoold` running and a socket your user can write to. Setup suggests `systemctl --user enable --now ydotool`, or running `ydotoold` as a user in the `input` group (`sudo usermod -aG input $USER`, then log in again). If it listens on a non-default socket, set `YDOTOOL_SOCKET`. Use it when `wtype` does not work on your compositor and you accept a daemon with keyboard-injection rights.

Limits you should know:

- **No password-field detection.** Linux has no general way to ask. Vizier will paste into a password box if the cursor is there.
- **Focus.** Vizier knows which app is focused on X11, Sway and Hyprland. If that app changed between the stop and the paste, the paste is held. On other desktops it cannot tell.
- **Held or failed pastes keep the text.** It stays on the clipboard if it got there, and `vizier last` always prints the last take's text. If the clipboard changed before the keys went out, nothing is sent.
- **No paste keys, no problem.** With no usable sender, the text stays on the clipboard and the notification says so. Paste it yourself.

## Local mode

`local` is the starter config's default mode. It sends audio to a whisper.cpp server on `127.0.0.1:8738` and nothing leaves your machine. Only loopback addresses are accepted. The exact steps are the ones `vizier doctor` prints for the `local_whisper` check:

1. Build [whisper.cpp](https://github.com/ggml-org/whisper.cpp) so `whisper-server` is on your `PATH`.
2. Download the model:

   ```bash
   curl -L --create-dirs -o ~/.local/share/vizier/models/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
   ```

3. Start the server:

   ```bash
   whisper-server -m ~/.local/share/vizier/models/ggml-large-v3-turbo.bin --host 127.0.0.1 --port 8738 --inference-path /v1/audio/transcriptions
   ```

Vizier does not start this server for you. Run it under your own systemd user unit or session script if you want it always up. A mode that uses a local cleanup model needs an OpenAI-style chat server too (for example llama.cpp's `llama-server`); doctor prints the command.

## Cloud modes

Keys are never command-line arguments. Pipe the key in, or type it at the hidden prompt:

```bash
printf %s "$KEY" | vizier key set gemini --stdin
vizier key set elevenlabs
vizier key status
vizier key delete gemini
```

`vizier key status` says where each key comes from and never prints it. Then pick a mode:

```bash
vizier config set mode scribe
```

The starter config defines `local`, `scribe` (ElevenLabs), `gemini-clean` and `gemini-smart` (Gemini). The Scribe and Gemini modes fall back to batch Gemini, then to local whisper if you are offline. The cloud modes send audio off your machine; see [privacy](privacy.md).

## Feedback

Notifications go over D-Bus (`notify-send` is the fallback). One notification is replaced in place as the take goes from recording to finalizing to its outcome. It carries the phase and the mode name, never your words or the app you paste into.

Sounds (start, stop, cancel, problem) play through `pw-play`, `paplay` or `aplay`. Turn them off by setting `VIZIER_SOUNDS=off` in the daemon's environment, for example with `systemctl --user edit vizier.service`.

## Privacy and where things live

| What | Where |
|---|---|
| Config, vocabulary, replacements | `~/.config/vizier/` (`vizier.jsonc`, `vocabulary.txt`, `replacements.txt`); `vizier config path` prints it |
| History and takes (audio and text) | `~/.local/share/vizier/` (`history.sqlite`, `Takes/`) |
| Whisper model, if you followed the steps above | `~/.local/share/vizier/models/` |
| API keys | The Secret Service keyring if `secret-tool` is installed and unlocked; otherwise `~/.config/vizier/keys.json`, mode 0600. The environment variables `VIZIER_ELEVENLABS_API_KEY` and `VIZIER_GEMINI_API_KEY` override both. |
| Socket and lock | `$XDG_RUNTIME_DIR/vizier/`; there is no `/tmp` fallback |

`XDG_CONFIG_HOME` and `XDG_DATA_HOME` move the first three rows. In local mode, audio and text stay on your machine. In cloud modes, audio and your vocabulary hints go to the provider you chose, and Gemini cleanup also sends the transcript. History commands show metadata only; `vizier history --text` and `vizier last` print text, so use them deliberately.

## Troubleshooting

Run `vizier doctor`. It prints each check as `ok`, `warn` or `fail` with a `fix` line, and exits 5 if any check fails. `vizier setup` checks the paste and hotkey side that doctor does not.

| Check | What it means | What to do |
|---|---|---|
| `runtime_dir` | `$XDG_RUNTIME_DIR` is missing, not yours, or not mode 0700 | Log in through a normal session; the variable must be absolute |
| `socket` | The daemon is not answering | `vizier daemon`, or `systemctl --user status vizier.service` and `journalctl --user -u vizier.service` |
| `config` | The settings, vocabulary or replacements file does not parse | `vizier config path`, fix the file. The last good config keeps running |
| `history` | The history database cannot be opened. It is created when the daemon first runs | `vizier daemon` |
| `libcurl` | The libcurl behind networking is older than 8.11 | Upgrade libcurl (`sudo apt-get update && sudo apt-get install libcurl4t64`). Batch engines still work |
| `pw_record` | Neither `pw-record` nor `parec` is installed | `sudo apt install pipewire-bin` (Fedora `pipewire-utils`, Arch `pipewire`, openSUSE `pipewire-tools`) |
| `local_whisper` | Nothing answers at `127.0.0.1:8738` | Follow [Local mode](#local-mode), or switch mode: `vizier config set mode <id>` |
| `local_cleanup` | The cleanup server a mode names is down | Start it, or choose a mode without cleanup |
| `take_session` | The daemon is down, or still recovering earlier takes (`startup_not_ready`) | Start the daemon, wait, try again |

Setup adds these, in its own output:

| Check | What it means | What to do |
|---|---|---|
| `desktop` | No `WAYLAND_DISPLAY` or `DISPLAY` | Run setup from a terminal in the session |
| `capture` | The recorder is missing | As `pw_record` |
| `clipboard` | No clipboard tool for this desktop | `wl-clipboard` on Wayland; `xclip` on X11 |
| `paste` | No way to send paste keys. Text stays on the clipboard | `wtype` on Wayland, `xdotool` on X11; on GNOME and KDE re-run `vizier setup` from the session |
| `hotkey` | No portal shortcut | Use the compositor bind above |
| `desktop_entry` | `net.praxient.vizier.desktop`, which the GNOME and KDE portals identify Vizier by, is not installed (a package or AppImage setup provides it) | `vizier setup` |
| `keys` | Which cloud keys are set | `vizier key set` |
| `sounds` | No player or sound files | Install PipeWire or PulseAudio client tools |
| `notifications` | Notifications go over D-Bus; `notify-send` only matters if D-Bus fails | Usually nothing |

Common cases:

- **The hotkey does nothing.** Run `vizier status`. If it says the daemon is down, start it. If it answers, the daemon is fine and the bind is not firing: on a compositor, check the config line and reload; on a portal desktop, re-run `vizier setup`.
- **Text is on the clipboard but not pasted.** Check the `paste` line from `vizier setup`, install the tool it names, and make sure the daemon sees your display variables ([First run](#first-run)).
- **Nothing useful pastes into a terminal.** The terminal may not be on the known list, so Ctrl+V went out. Paste with Ctrl+Shift+V yourself; the text is on the clipboard.
- **You lost a take's text.** `vizier last` prints it.

## What is not verified

This is the first Linux release, and parts of it have not met a real desktop.

- The GNOME and KDE portal flows (consent, clipboard, paste keys) and the portal hotkey were tested against a mock of the portal, not a real GNOME or KDE session. Whether the chord appears and can be changed in the desktop's settings is unconfirmed.
- Hyprland, river, niri and the other compositors were not run on a real session.
- X11 and a headless Sway were tested end to end.

If something here does not match what your desktop does, `vizier doctor --json` and `vizier setup --json` give the details to report.
