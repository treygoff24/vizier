// Read the focused app ID on COSMIC. Window titles are discarded immediately.
// Version 1 remains supported by COSMIC and needs no privileged input access.
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include "protocols/cosmic-toplevel.h"

struct window {
    struct window *next;
    char *app_id;
    bool active;
    bool closed;
};
static struct window *windows;
static bool available;

static void closed(void *data, struct zcosmic_toplevel_handle_v1 *handle) {
    ((struct window *)data)->closed = true;
}
static void done(void *data, struct zcosmic_toplevel_handle_v1 *handle) {}
static void title(void *data, struct zcosmic_toplevel_handle_v1 *handle, const char *text) {}
static void app_id(void *data, struct zcosmic_toplevel_handle_v1 *handle, const char *text) {
    struct window *window = data;
    free(window->app_id);
    window->app_id = strdup(text);
}
static void output(void *data, struct zcosmic_toplevel_handle_v1 *handle, struct wl_output *out) {}
static void workspace(void *data, struct zcosmic_toplevel_handle_v1 *handle, struct zcosmic_workspace_handle_v1 *space) {}
static void state(void *data, struct zcosmic_toplevel_handle_v1 *handle, struct wl_array *states) {
    struct window *window = data;
    window->active = false;
    uint32_t *value;
    wl_array_for_each(value, states) {
        if (*value == ZCOSMIC_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) window->active = true;
    }
}
static const struct zcosmic_toplevel_handle_v1_listener window_listener = {
    .closed = closed, .done = done, .title = title, .app_id = app_id,
    .output_enter = output, .output_leave = output,
    .workspace_enter = workspace, .workspace_leave = workspace, .state = state,
};
static void toplevel(void *data, struct zcosmic_toplevel_info_v1 *info, struct zcosmic_toplevel_handle_v1 *handle) {
    struct window *window = calloc(1, sizeof(*window));
    if (!window) exit(2);
    window->next = windows;
    windows = window;
    zcosmic_toplevel_handle_v1_add_listener(handle, &window_listener, window);
}
static void finished(void *data, struct zcosmic_toplevel_info_v1 *info) {}
static const struct zcosmic_toplevel_info_v1_listener info_listener = {
    .toplevel = toplevel, .finished = finished,
};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (strcmp(interface, zcosmic_toplevel_info_v1_interface.name) == 0) {
        struct zcosmic_toplevel_info_v1 *info = wl_registry_bind(registry, name, &zcosmic_toplevel_info_v1_interface, 1);
        zcosmic_toplevel_info_v1_add_listener(info, &info_listener, NULL);
        available = true;
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {global, removed};
int vizier_cosmic_focused_app(void) {
    alarm(2); // Bound roundtrips if the compositor is unresponsive.
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    for (int i = 0; i < 3; i++) {
        if (wl_display_roundtrip(display) < 0) return 1;
    }
    int result = 1;
    if (available) {
        for (struct window *window = windows; window; window = window->next) {
            if (window->active && !window->closed && window->app_id && *window->app_id) {
                puts(window->app_id);
                result = 0;
                break;
            }
        }
    }
    wl_display_disconnect(display);
    while (windows) {
        struct window *next = windows->next;
        free(windows->app_id);
        free(windows);
        windows = next;
    }
    return result;
}
