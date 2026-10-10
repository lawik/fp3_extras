# Display

## DRM on the Adreno 506

The panel is driven by the msm display controller at `/dev/dri/card0`
(`card1` is the GPU's render node's card). Emerge renders with OpenGL ES
through Mesa's freedreno driver straight to the panel through DRM/KMS.
The panel is 1080x2160 at about 430 dpi; a UI laid out at 432x864
points scales by 2.5.

Three things found on the way:

* **GMEM tiling hung on MSAA depth/stencil.** Freedreno counted the
  samples of depth and stencil MSAA attachments twice when sizing tiles,
  so an ordinary 4x MSAA batch didn't fit the Adreno 506's 136 KiB of
  GMEM and the tile-size search spun at 100% CPU for tens of seconds per
  frame. Setting `FD_MESA_DEBUG=sysmem` in `vm.args` bypassed tiling;
  nerves_system_fp3 v0.2.4 patches Mesa (count once, and fall back to
  sysmem when nothing fits), so the variable can go.
* **The renderer cache skipped frames.** Emerge 0.4.2's DRM presenter
  could skip a scene that arrived while an older one was staged behind a
  page flip (a tap's press style, then the screen it opens): it took the
  new scene's fingerprint when it submitted the old one, then counted
  the new one as already shown, and the screen stayed stale until the
  next touch. `renderer_cache: [enabled: false]` in the viewport
  options avoids it.
* **No hardware cursor.** `hw_cursor: false`; there's no pointer.

## The kernel console on the panel

The boot arguments are `console=tty0 loglevel=8 fbcon=rotate:3
fbcon=font:TER16x32`: the kernel draws every message on the panel,
rotated, in a 16x32 font. While booting that's the only display there
is. Once a DRM application owns the panel, fbcon still renders every
message into the framebuffer behind it, and a burst stalls the system:
after a resume from suspend the camera drivers print two WARN
backtraces, and with fbcon bound that froze the BEAM for about eleven
seconds, against about one with it unbound. `Fairphone3Extras.Console`
unbinds the framebuffer console (`/sys/class/vtconsole/vtconN/bind`) and
can lower the console log level (`/proc/sys/kernel/printk`); messages
stay in the log buffer either way.

## Backlight

`/sys/class/backlight/*`: `brightness` 0..4095 (0 is black; 1 is the
dimmest visible), `bl_power` 0 for on, 4 for off. Off keeps `brightness`,
so turning back on lights the panel at the old level: set `brightness`
to 0 first when fading in. `Fairphone3Extras.Backlight` maps percent to
raw on a 2.2 power curve, so 50% looks like half and a fade stepped in
percent looks even.

`Fairphone3Extras.Screen` is the state machine on top: on, dim (35% of
the on level, at least 2.5%), off; fades of about a second to dim, 800 ms
to black, 250 ms to wake; a 20 ms tick; the backlight powered off once
black. Touches wake it. Automatic brightness measures the light when
turned on, on waking and every minute while on.

Backlight off saves only about 20 mW against the screen on at 60%
(0.90 W against 0.92 W idle on 2026-10-10); the panel and the display
pipeline stay powered. Turning the display pipeline off (DRM DPMS, or
releasing the card) is the unmeasured lever.

## Ambient light

There's no light sensor. The ADSP's sensor manager exposes
accelerometer, gyroscope, magnetometer, pressure and proximity; the
proximity sensor is binary. `Fairphone3Extras.LightSensor` uses the
front camera instead: two binned frames at two exposures, the raw green
mean's slope with exposure, scaled to unity gain, about 1.2 s. The black
level cancels out. Rough calibration: a dim room measured 0.00075 raw
counts per exposure line at unity gain.

## Orientation

The accelerometer is mounted a quarter turn from the screen: held
upright, its x axis reads +9.8 m/s². `Fairphone3Extras.Orientation`
maps sensor axes to screen axes (`[x: {:y, 1}, y: {:x, 1}]` by default),
needs a tilt within 30° of upright or sideways held for half a second
to switch, and keeps the last orientation while lying flat.

## Touch

The touchscreen is an evdev device with multitouch positions. Emerge
reads it for the UI; `Fairphone3Extras.Buttons` reads it too, for touch
activity only. evdev gives every reader every event, so both see all
touches. The touch that wakes a black screen reaches the UI as well, so
the UI should swallow it (a full-screen catcher while the screen is off)
or the wake-up tap presses whatever was under the finger.
