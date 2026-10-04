# Vizier on Linux

Vizier 0.2.0 is the first release with Linux support. It runs the same take engine as the Mac app. Tested end to end on X11, headless Sway and Pop!_OS COSMIC; see [What is not verified](#what-is-not-verified) for what has not met a real desktop.

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
- `Vizier-0.2.0-x86_64.AppImage`. Make it executable (`chmod +x`) and keep it somewhere permanent. It takes the same arguments as the `vizier` command (`./Vizier-0.2.0-x86_64.AppImage setup`), and setup points the service and desktop entry at that path. It uses your system's libraries (libcurl, SQLite, libsystemd, libwayland-client) instead of bundling them.

Later releases name their files the same way with their own version.

To build from source, install the Wayland development headers (`sudo apt install libwayland-dev` on Debian/Ubuntu) and Swift 6.4 with [swiftly](https://www.swift.org/install/linux/), then:

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
| Pop!_OS COSMIC (Wayland) | `wl-copy` | `ydotool`, selected automatically; see [COSMIC setup](#pop_os-cosmic) |
| X11 | `xclip` or `xsel` | `xdotool` |
| Other desktops, opt-in | | `ydotool`, tried last, only when `VIZIER_YDOTOOL=1` is set in the daemon's environment |

Install what your row names: for example `sudo apt install wl-clipboard wtype`, or `sudo apt install xclip xdotool`.

**ydotool** types through the kernel's uinput device. It needs `ydotoold` running and a socket your user can write to. Setup suggests `systemctl --user enable --now ydotool`, or running `ydotoold` as a user in the `input` group (`sudo usermod -aG input $USER`, then log in again). If it listens on a non-default socket, set `YDOTOOL_SOCKET`. Use it when `wtype` does not work on your compositor and you accept a daemon with keyboard-injection rights.

Limits you should know:

- **No password-field detection.** Linux has no general way to ask. Vizier will paste into a password box if the cursor is there.
- **Focus.** Vizier knows which app is focused on X11, Sway and Hyprland. If that app changed between the stop and the paste, the paste is held. COSMIC supplies an app ID for terminal detection but no PID for this guard; keep the intended window focused until paste finishes. On other desktops it cannot tell.
- **Held or failed pastes keep the text.** It stays on the clipboard if it got there, and `vizier last` always prints the last take's text. If the clipboard changed before the keys went out, nothing is sent.
- **No paste keys, no problem.** With no usable sender, the text stays on the clipboard and the notification says so. Paste it yourself.

## Pop!_OS COSMIC

This integration is selected automatically for a Wayland session whose
`XDG_CURRENT_DESKTOP` contains `COSMIC`. There is no `VIZIER_YDOTOOL` opt-in,
PATH shim, or separate focus-helper installation. The native focus helper ships
inside the Linux executable, including packages and AppImages.

COSMIC can accept `wtype` and report success while producing incorrect keys.
Vizier therefore uses `wl-copy` plus `ydotool` raw evdev paste chords. The bundled
reader obtains the focused app ID through COSMIC's toplevel protocol: known
terminals receive Ctrl+Shift+V; other apps receive Ctrl+V. If focus is unavailable,
no keys are sent and the transcript remains on the clipboard for manual paste.
The reader discards window titles and times out if the compositor stops answering.

### Installation and first take

1. Install a Vizier build containing this support, plus the capture, conversion
   and clipboard tools:

   ```bash
   sudo apt install pipewire-bin ffmpeg wl-clipboard
   ```

2. Install **ydotool and ydotoold 1.0 or newer** together, where the user service
   can find them (for example `/usr/local/bin`). Check `ydotool --version`.
   Pop!_OS 24.04's Ubuntu package can be the older 0.1.8 release; that version
   does not provide the daemon/socket interface used here. Follow
   [ydotool's build instructions](https://github.com/ReimuNotMoe/ydotool#build).
   The daemon needs this user to have read/write access to `/dev/uinput`.
   Use an existing administrator-approved device rule or input group setup.
   Input access permits keyboard injection; Vizier setup does not grant it,
   run sudo, or change device/group permissions.

3. From a terminal in COSMIC, run:

   ```bash
   vizier setup --autostart
   ```

   When no usable input socket exists and the helpers are installed, setup writes
   `vizier-input.service` and a `vizier.service.d/cosmic-input.conf` dependency.
   With device access and `--autostart`, it enables the input service and checks
   socket readiness. Without `--autostart`, it only writes the files. The private
   socket is `$XDG_RUNTIME_DIR/vizier-input/socket` (0600), inside a 0700 directory.
   Existing user units are preserved. A running input service is reused;
   `YDOTOOL_SOCKET` still takes precedence when explicitly configured.
   Missing helpers, permissions or socket readiness produce a warning and leave
   clipboard-only dictation available.

4. In **COSMIC Settings → Input devices → Keyboard → Keyboard shortcuts → Custom**,
   add the two commands printed by setup: **Ctrl+Alt+Space** runs the absolute
   Vizier path followed by `toggle`; **Ctrl+Alt+Backspace** runs it with `cancel`.
   Setup leaves existing keyboard bindings untouched. The AppImage instructions
   use the persistent AppImage path, not its temporary mount.

5. Start the [local speech server](#local-mode), focus a text field, press the
   toggle chord, speak, and press it again. Local Whisper transcribes after stop.
   This Linux integration provides notifications and sounds, not a live transcript
   overlay. Stock libcurl 8.5 can handle this local batch route even though the
   current doctor reports its separate live-cloud/WebSocket requirement as a failure.

For the tested lightweight English setup, use `ggml-small.en-q5_1.bin` from
[whisper.cpp's models](https://huggingface.co/ggerganov/whisper.cpp/tree/main), and
edit the local mode's `transcriber.model` to `small.en-q5_1` in the file shown by
`vizier config path`. Point `whisper-server -m` at that same file. This is an
optional model choice; setup preserves existing config and the upstream default.

### Optional NVIDIA acceleration, including GTX 1060

Desktop support does not depend on a GPU. On the tested GTX 1060 6 GB, native
whisper.cpp with CUDA 12.6 and explicit `sm_61` kernels worked; a recent PyTorch
wheel on that machine did not include kernels for this card. No PyTorch package
is needed. CUDA libraries can live beside the speech server so an existing Python
installation and system NVIDIA driver remain unchanged.

With a working driver and a CUDA 12.6 toolkit installed at a chosen path, build a
separate server from whisper.cpp (tested commit
`60c0be6ac8fa71b1a2ae2dd938a31a34a508e774`):

```bash
cmake -S whisper.cpp -B whisper.cpp/build-cuda \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_CURL=OFF \
  -DGGML_CUDA=ON -DCUDAToolkit_ROOT=/path/to/cuda-12.6 \
  -DCMAKE_CUDA_COMPILER=/path/to/cuda-12.6/bin/nvcc \
  -DCMAKE_CUDA_ARCHITECTURES=61-real -DGGML_CUDA_FA_ALL_QUANTS=OFF
cmake --build whisper.cpp/build-cuda --target whisper-server -j 4
```

`61-real` is specific to the GTX 1060's compute capability; select the architecture
for your GPU using [NVIDIA's table](https://developer.nvidia.com/cuda/gpus/legacy).
Keep the CPU binary and its service command. Launch the GPU binary on the same
loopback endpoint, with the same model and `--convert`; ensure its CUDA shared
libraries can be resolved, using a wrapper with a private `LD_LIBRARY_PATH` if
needed. Do not run CPU and GPU servers on the same port simultaneously.
For a user service, include `Restart=on-failure` and use `StandardOutput=null`
and `StandardError=null` because whisper.cpp can print recognized words.
Enable it under `graphical-session.target`. Stop dictation before changing speech
backends, wait for the new server to answer, then resume. Roll back by restoring
the preserved CPU server command and restarting that speech service.

On one i7-8700K / GTX 1060 machine, synthetic 5-, 18- and 37-second English clips
with `small.en-q5_1` took median 0.275, 0.487 and 0.895 seconds on GPU, versus
2.853, 3.339 and 8.803 seconds on CPU (three requests per clip after warmup;
CPU six threads, GPU two host threads). These are HTTP recognition times,
including conversion, not recording or desktop paste time. Normalized CPU/GPU
outputs matched on all nine requests. GPU memory use was about 515 MiB; the card
returned to its previous idle power state between workloads. These measurements
do not establish general accuracy, whole-system energy savings or fan noise.

### Troubleshooting and rollback

- `systemctl --user status vizier-input.service`: check device access and the
  ydotool version if automatic paste is unavailable.
- `vizier doctor --json`: check desktop detection, clipboard helpers and socket
  availability. When focus cannot be read, paste the clipboard manually.
- To remove setup's managed input service, first remove only
  `~/.config/systemd/user/vizier.service.d/cosmic-input.conf`, then run
  `systemctl --user disable --now vizier-input.service` and
  `systemctl --user daemon-reload`. Remove its unit file only if setup created it;
  preserve pre-existing input services. Remove the two shortcuts in COSMIC Settings.
  Dictation can still leave text on the clipboard for manual paste.

## Local mode

`local` is the starter config's default mode. It sends audio to a whisper.cpp server on `127.0.0.1:8738` and nothing leaves your machine. Only loopback addresses are accepted. The exact steps are the ones `vizier doctor` prints for the `local_whisper` check:

1. Build [whisper.cpp](https://github.com/ggml-org/whisper.cpp) so `whisper-server` is on your `PATH`.
2. Download the model:

   ```bash
   curl -L --create-dirs -o ~/.local/share/vizier/models/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
   ```

3. Start the server:

   ```bash
   whisper-server -m ~/.local/share/vizier/models/ggml-large-v3-turbo.bin --host 127.0.0.1 --port 8738 --inference-path /v1/audio/transcriptions --convert
   ```

`--convert` enables FLAC input through ffmpeg; Vizier saves takes as FLAC. Install ffmpeg alongside the server.

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
- Pop!_OS 24.04 COSMIC was tested with a native Wayland GTK text field and Ghostty, using synthetic speech through a local GPU server. Cancellation inserted no text. A fresh login/reboot and the packaged AppImage were not exercised for this change.

If something here does not match what your desktop does, `vizier doctor --json` and `vizier setup --json` give the details to report.
