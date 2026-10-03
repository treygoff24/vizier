# Linux desktop files

Two files packaging installs; `vizier setup` writes the service for a per-user install.

| File | Install to | Why |
|---|---|---|
| `net.praxient.vizier.desktop` | `/usr/share/applications/` (or `~/.local/share/applications/`) | The GNOME and KDE desktop portals (RemoteDesktop paste, GlobalShortcuts) identify an app by its desktop-file id. `NoDisplay=true` keeps it out of app menus. `Exec=vizier daemon` must name the installed binary. |
| `vizier.service` | `/usr/lib/systemd/user/` (package) or `~/.config/systemd/user/` (`vizier setup`) | Starts `vizier daemon` with the graphical session and restarts it on failure. `@VIZIER_BIN@` is the absolute path of the binary (`/usr/bin/vizier` in a package). `TimeoutStopSec=15` stays above the daemon's 5 s shutdown deadline, so an active take's audio is saved before systemd kills it. |

A package installs the service with `@VIZIER_BIN@` replaced, then users run
`systemctl --user enable --now vizier.service` (or `vizier setup --autostart`).

The sounds (`start.wav`, `stop.wav`, `problem.wav`, `cancel.wav` from `Resources/Sounds`) go to
`/usr/share/vizier/sounds/`; the daemon also finds them at `../share/vizier/sounds` next to the binary.

The systemd user manager does not have the variables of your terminal, and the paste tools and
the portals need the desktop's: `WAYLAND_DISPLAY`/`DISPLAY`, `XDG_CURRENT_DESKTOP` and the rest.
Whether a session imports them into the user manager at login depends on the session (some
compositors' startup scripts do, others do not), so do not rely on it. `vizier setup --autostart`
runs `systemctl --user import-environment` with an explicit list of the variables that are set in
the shell it runs from (`WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`, `XDG_SESSION_TYPE`,
`XDG_CURRENT_DESKTOP`, `XDG_RUNTIME_DIR`, `XDG_DATA_DIRS`, `XDG_CONFIG_DIRS`, `SWAYSOCK`,
`HYPRLAND_INSTANCE_SIGNATURE`, `DBUS_SESSION_BUS_ADDRESS`), never the whole environment, before it
enables the unit. A package that enables the unit itself should do the same from the session's
startup script.

Under an AppImage, `vizier setup` writes the unit's `ExecStart` and the desktop file's `Exec` with
the AppImage's own path (`$APPIMAGE`), not the transient mount the running binary sees, and installs
`net.praxient.vizier.desktop` into `$XDG_DATA_HOME/applications`. With a package install both files
already exist under `/usr`, and setup only checks them. `vizier doctor` reports a `desktop_entry`
check for the portal's desktop file.

Unverified: nothing here has run on a real desktop yet.
