# Display

## DRM

The msm display controller is `/dev/dri/card0` (`card1` is the GPU's
render node). A DRM client renders with OpenGL ES through Mesa's
freedreno and presents through KMS. The panel is 1080x2160 at about
430 dpi.

## The kernel console

`console=tty0 loglevel=8 fbcon=rotate:3 fbcon=font:TER16x32` draws every
kernel message on the panel. Once a DRM application owns the panel,
fbcon still renders behind it and a burst stalls the system: the two
camera WARN backtraces after a resume froze the BEAM for about eleven
seconds with fbcon bound, one unbound. `Fp3Extras.Console` unbinds it
and can lower the console log level; messages stay in the log buffer.

## Backlight

`brightness` 0..4095 (1 is the dimmest visible), `bl_power` 0 on, 4 off.
Off keeps `brightness`, so set it to 0 before powering on when fading
in. `Fp3Extras.Backlight` maps percent to raw on a 2.2 curve.

`Fp3Extras.Screen` is the state machine: on, dim (35% of on, at least
2.5%), off; fades of a second to dim, 800 ms to black, 250 ms to wake;
backlight powered off once black. Backlight off saves about 20 mW; the
display pipeline stays up.

## Powering the panel down

`/sys/class/graphics/fb0/blank` reaches the DRM driver's DPMS through
fbdev emulation: `4` powers pipeline and panel down (about 340 mW), `0`
brings them back. `Fp3Extras.Panel.blank/1` wraps it. The fb helper
defers to a DRM master, so with a client holding the display the write
does nothing. Timed with the client stopped: blank about 275 ms, unblank
about 600 ms. The sequence is in the suspend guide. Suspend to idle takes
the display down regardless.

## Ambient light

There's no light sensor. `Fp3Extras.LightSensor` uses the front camera:
two binned frames at two exposures, the raw green mean's slope with
exposure, scaled to unity gain; about 1.2 s. A dim room measured 0.00075
counts per exposure line.

## Orientation

The accelerometer is mounted a quarter turn from the screen: upright,
its x reads +9.8 m/s². `Fp3Extras.Orientation` maps sensor to screen
axes (`[x: {:y, 1}, y: {:x, 1}]`), needs a tilt within 30° held for half
a second, and keeps the last orientation lying flat.

## Touch

The touchscreen is an evdev multitouch device. evdev gives every reader
every event, so a UI toolkit and `Fp3Extras.Buttons` both see touches.
The touch that wakes a black screen reaches the UI too: swallow it.
