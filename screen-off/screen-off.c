/* screen-off -- keep the screens off while a long job runs

   Usage: screen-off PID [SECONDS]

   Turns every screen of the Wayland session off a second after the last
   input, and on again at the next input (a mouse move, a key).  After that
   they go off whenever there has been no input for SECONDS (default 60).
   `guix bump --screen-off' starts it for `guix nightly'.

   It runs as long as process PID does.  When PID is gone and the screens
   are on, it exits; when they are off, it waits for the next input, turns
   them on and exits, so an error message stays readable in the morning
   without the screens glowing all night.  SIGINT, SIGTERM and SIGHUP turn
   the screens on and end it.

   Input is watched with ext-idle-notify version 2's input idle
   notifications, which ignore idle inhibitors: a video or an app that keeps
   the session awake must not keep the screens on through the night.  The
   screens are switched with wlr-output-power-management.  COSMIC, sway,
   Hyprland and other wlroots-style compositors have both.  */

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <wayland-client.h>
#include "ext-idle-notify-v1-client-protocol.h"
#include "wlr-output-power-management-unstable-v1-client-protocol.h"

struct output
{
  uint32_t name;                          /* registry name */
  struct wl_output *output;
  struct zwlr_output_power_v1 *power;
  struct output *next;
};

static struct wl_registry *registry;
static struct wl_seat *seat;
static struct ext_idle_notifier_v1 *notifier;
static uint32_t notifier_version;
static struct zwlr_output_power_manager_v1 *power_manager;
static struct output *outputs;

static int screens_off;          /* what was last asked of the screens */
static int woken;                /* the user has been back since the start */
static volatile sig_atomic_t stop;

/* The two notifications; their listener data says which one fired.  */
static char first_idle[] = "first";
static char later_idle[] = "later";

static void
power_failed (void *data, struct zwlr_output_power_v1 *power)
{
  /* This output can't be switched (or went away): forget its handle.  */
  struct output *o = data;
  zwlr_output_power_v1_destroy (power);
  o->power = NULL;
}

static void
power_mode (void *data, struct zwlr_output_power_v1 *power, uint32_t mode)
{
  (void) data; (void) power; (void) mode;
}

static const struct zwlr_output_power_v1_listener power_listener =
  { power_mode, power_failed };

static void
set_mode (struct output *o)
{
  if (!o->power && power_manager)
    {
      o->power = zwlr_output_power_manager_v1_get_output_power (power_manager,
                                                                o->output);
      zwlr_output_power_v1_add_listener (o->power, &power_listener, o);
    }
  if (o->power)
    zwlr_output_power_v1_set_mode (o->power,
                                   screens_off
                                   ? ZWLR_OUTPUT_POWER_V1_MODE_OFF
                                   : ZWLR_OUTPUT_POWER_V1_MODE_ON);
}

static void
set_screens (int off)
{
  if (off == screens_off)
    return;
  screens_off = off;
  for (struct output *o = outputs; o; o = o->next)
    set_mode (o);
}

static void
idled (void *data, struct ext_idle_notification_v1 *notification)
{
  (void) notification;
  /* The short notification only blanks at the start; afterwards the long
     one does, so that a look at the screen lasts more than a second.  */
  if (data == later_idle || !woken)
    set_screens (1);
}

static void
resumed (void *data, struct ext_idle_notification_v1 *notification)
{
  (void) data; (void) notification;
  woken = 1;
  set_screens (0);
}

static const struct ext_idle_notification_v1_listener idle_listener =
  { idled, resumed };

static void
add_global (void *data, struct wl_registry *reg, uint32_t name,
            const char *interface, uint32_t version)
{
  (void) data;
  if (strcmp (interface, wl_seat_interface.name) == 0 && !seat)
    seat = wl_registry_bind (reg, name, &wl_seat_interface, 1);
  else if (strcmp (interface, ext_idle_notifier_v1_interface.name) == 0)
    {
      notifier_version = version < 2 ? version : 2;
      notifier = wl_registry_bind (reg, name, &ext_idle_notifier_v1_interface,
                                   notifier_version);
    }
  else if (strcmp (interface,
                   zwlr_output_power_manager_v1_interface.name) == 0)
    power_manager = wl_registry_bind (reg, name,
                                      &zwlr_output_power_manager_v1_interface,
                                      1);
  else if (strcmp (interface, wl_output_interface.name) == 0)
    {
      struct output *o = calloc (1, sizeof *o);
      if (!o)
        return;
      o->name = name;
      o->output = wl_registry_bind (reg, name, &wl_output_interface, 1);
      o->next = outputs;
      outputs = o;
      /* A screen plugged in while the others are off goes off too.  */
      if (screens_off)
        set_mode (o);
    }
}

static void
remove_global (void *data, struct wl_registry *reg, uint32_t name)
{
  (void) data; (void) reg;
  for (struct output **p = &outputs; *p; p = &(*p)->next)
    if ((*p)->name == name)
      {
        struct output *o = *p;
        *p = o->next;
        if (o->power)
          zwlr_output_power_v1_destroy (o->power);
        wl_output_destroy (o->output);
        free (o);
        return;
      }
}

static const struct wl_registry_listener registry_listener =
  { add_global, remove_global };

static void
on_signal (int sig)
{
  (void) sig;
  stop = 1;
}

static struct ext_idle_notification_v1 *
watch (uint32_t ms, void *which)
{
  struct ext_idle_notification_v1 *n =
    notifier_version >= 2
    ? ext_idle_notifier_v1_get_input_idle_notification (notifier, ms, seat)
    : ext_idle_notifier_v1_get_idle_notification (notifier, ms, seat);
  ext_idle_notification_v1_add_listener (n, &idle_listener, which);
  return n;
}

int
main (int argc, char *argv[])
{
  if (argc < 2 || argc > 3)
    {
      fprintf (stderr, "usage: %s PID [SECONDS]\n", argv[0]);
      return 2;
    }
  pid_t pid = atoi (argv[1]);
  long seconds = argc == 3 ? atol (argv[2]) : 60;
  if (pid <= 0 || seconds <= 0 || seconds > 24 * 3600)
    {
      fprintf (stderr, "%s: bad PID or SECONDS\n", argv[0]);
      return 2;
    }

  struct wl_display *display = wl_display_connect (NULL);
  if (!display)
    {
      fprintf (stderr, "screen-off: no Wayland session\n");
      return 1;
    }
  registry = wl_display_get_registry (display);
  wl_registry_add_listener (registry, &registry_listener, NULL);
  wl_display_roundtrip (display);
  if (!seat || !notifier || !power_manager)
    {
      fprintf (stderr, "screen-off: the compositor can't %s\n",
               !power_manager ? "switch screens off (wlr-output-power-management)"
               : "report idleness (ext-idle-notify)");
      return 1;
    }
  if (notifier_version < 2)
    fprintf (stderr, "screen-off: ext-idle-notify version 1 only: an app "
             "that inhibits idleness keeps the screens on\n");

  struct sigaction sa;
  memset (&sa, 0, sizeof sa);
  sa.sa_handler = on_signal;             /* no SA_RESTART: poll returns */
  sigaction (SIGINT, &sa, NULL);
  sigaction (SIGTERM, &sa, NULL);
  sigaction (SIGHUP, &sa, NULL);

  watch (1000, first_idle);
  watch (seconds * 1000, later_idle);

  int status = 0;
  while (!stop)
    {
      if (wl_display_flush (display) < 0 && errno != EAGAIN)
        {
          status = 1;
          break;
        }
      struct pollfd fd = { wl_display_get_fd (display), POLLIN, 0 };
      int ready = poll (&fd, 1, 1000);
      if (ready > 0 && wl_display_dispatch (display) < 0)
        {
          status = 1;                    /* the compositor went away */
          break;
        }
      if (ready < 0 && errno != EINTR)
        {
          status = 1;
          break;
        }
      /* The job is over: leave once the screens are on.  */
      if (kill (pid, 0) < 0 && errno == ESRCH && !screens_off)
        break;
    }

  set_screens (0);
  wl_display_roundtrip (display);
  wl_display_disconnect (display);
  return status;
}
