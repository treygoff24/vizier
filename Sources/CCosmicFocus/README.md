# COSMIC focus reader

Linux-only, linked into `vizier`. The private `--cosmic-focused-app` entry point
runs before CLI/config/daemon initialization and exits after printing one app ID.
The parent runs it with a timeout; the child also bounds blocking Wayland
roundtrips. Window titles are discarded, never printed or stored. Protocol v1
is sufficient for app IDs and activated state; newer COSMIC compositors retain it.
This API supplies no process ID, so it cannot implement the PID-based focus-move
guard available on X11, Sway and Hyprland.

`protocols/` contains generated Wayland bindings, with upstream copyright and
permission notices retained. Generated files are committed so installing/building
Vizier needs `libwayland-dev`, not a protocol checkout or `wayland-scanner`.
The workspace and ext bindings satisfy symbols referenced by the toplevel binding;
Vizier only binds the COSMIC toplevel-info global, at version 1.

Generated with `wayland-scanner 1.23.1`:

- [cosmic-protocols](https://github.com/pop-os/cosmic-protocols/tree/c0cff4db14c37ed954983158e4055aa94c7741d9/unstable):
  `cosmic-toplevel-info-unstable-v1.xml` → `cosmic-toplevel.h` (client-header) and
  `cosmic-toplevel.c` (private-code);
  `cosmic-workspace-unstable-v1.xml` → `cosmic-workspace.c` (private-code).
- [wayland-protocols](https://github.com/wayland-mirror/wayland-protocols/tree/819004adb3ab7e46f3fa3caef05b96e20434b244):
  `staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml` →
  `ext-toplevel.c` (private-code);
  `staging/ext-workspace/ext-workspace-v1.xml` → `ext-workspace.c` (private-code).

For example: `wayland-scanner private-code input.xml output.c`.
