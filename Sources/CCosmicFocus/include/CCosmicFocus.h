#pragma once
// Only call in the one-shot --cosmic-focused-app subprocess, never in the daemon.
// Prints the active app ID, never a title. Exits nonzero if focus is unavailable.
int vizier_cosmic_focused_app(void);
