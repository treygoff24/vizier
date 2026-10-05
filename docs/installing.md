# Installing Vizier

This page is for the Mac app. For Linux, see [Vizier on Linux](linux.md).

## Requirements

- macOS 26 or later on Apple Silicon.
- A microphone. Vizier records from the system's default input device.
- Optional: an ElevenLabs or Google Gemini API key, for the cloud modes. The default mode needs neither.

## Install from the DMG

1. From the [latest GitHub release](https://github.com/treygoff24/vizier/releases/latest), download the `Vizier-x.y.z.dmg` file (for example `Vizier-0.1.0.dmg`).
2. Open the DMG and drag Vizier onto the Applications shortcut inside it.
3. Open Vizier from Applications.

Vizier is a menu bar app. It shows an icon in the menu bar and no Dock icon until one of its windows is open. Settings › General has a Show in Dock switch if you want the icon always.

## First run: the setup guide

The setup guide opens the first time you run Vizier. It has seven steps, each can be skipped, and the welcome screen says setup is quick and needs no account, apart from a one-time speech-model download whose time depends on your connection.

1. **Welcome.**
2. **Microphone.** macOS asks for access to the microphone. Vizier cannot record without it.
3. **Accessibility.** Vizier needs Accessibility access for two things: seeing your hotkey while another app is in front, and sending the paste keystroke to that app. The step checks once a second and moves on when the grant appears. If Vizier is not in the Accessibility list, or is there but not working, the step shows a hint: remove Vizier from the list and add it again.
4. **Speech model.** Apple's speech recognizer needs a one-time download of the model for your system language. If Apple does not support that language the step shows Unsupported and points you to the cloud modes; see [Languages](modes-and-config.md#languages). The default mode uses it, and so does the Apple fallback that the cloud modes end with.
5. **Hotkey.** Choose Right Command (the default), Right Option or Right Control. Most laptop keyboards have no Right Control. See [using Vizier](using.md#the-hotkey).
6. **Higher accuracy.** Optionally enter an ElevenLabs key, a Gemini key, or both. You can also do this later in Settings › Accounts. See [modes and configuration](modes-and-config.md).
7. **Practice.** Take a trial dictation. The words are sent into the setup window, so nothing is typed into another app.

To see the guide again, click Setup guide in the menu bar popover, or use Settings › About › Open setup guide.

## Open at Login

The first time you run a copy that lives in `/Applications` or `~/Applications`, Vizier turns on Open at Login. You can turn it off in Settings › General. A copy run from anywhere else, such as a `build/` folder, never registers itself.

## Permissions

| Permission | Why | If it is missing |
|---|---|---|
| Microphone | Recording | The take cannot record and the strip says so |
| Accessibility | Watching the hotkey and pasting | The hotkey does nothing, or the text stays on the clipboard instead of pasting |
| Automation of System Events | Only for keyboard layouts that do not put V on the standard key under Command (some Dvorak and Colemak layouts), where Vizier pastes through System Events | macOS asks for permission the first time it is needed |

Grant them in System Settings › Privacy & Security.

## Updates

Release builds update themselves through [Sparkle](https://sparkle-project.org). Check for updates is in the menu bar popover and in Settings › About. Vizier checks the feed at `https://github.com/treygoff24/vizier/releases/latest/download/appcast.xml`.

The updater runs only in a copy whose code signature is valid and carries a team identifier, as the released DMG does. A copy you build yourself is signed ad hoc, has no team identifier, never updates itself, and shows Check for updates greyed out with the note "Updates come with the signed release." To see whether your copy can update, run:

```bash
/Applications/Vizier.app/Contents/MacOS/Vizier --version
```

It prints the version, the build number, and whether the updater is eligible or off.

## Removing Vizier

Turn off Open at Login in Settings › General, quit Vizier from the menu bar popover, and delete the app. Your data stays until you delete it. It is in `~/.config/vizier/`, `~/Library/Application Support/Vizier/`, and the Keychain items under the service `net.praxient.dictum`. See [privacy](privacy.md#what-is-stored-on-your-mac).
