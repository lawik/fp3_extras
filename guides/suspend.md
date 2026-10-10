# Suspend, wake and power

`Fp3Extras.Sleep` is the sleep sequence; `Fp3Extras.Power`,
`Fp3Extras.WiFi`, `Fp3Extras.Console` and `Fp3Extras.Battery` are its
parts.

## What the phone draws

Measured with the charger's USB input suspended
(`Fp3Extras.Battery.measure/2`). Idle, Wi-Fi up, no SIM:

| State | Draw |
|---|---|
| UI up, screen on at half brightness | 0.92 W |
| Backlight off | 0.90 W |
| Plus the ADSP sensor streams stopped | 0.76 W |
| Plus the BEAM on two schedulers | 0.68 W |
| DRM client stopped, display pipeline down, sensors running | 0.60 W |

Awake: power the pipeline down (340 mW), stop the sensors (140 mW), keep
the BEAM on two schedulers (75 mW). Even so, about 0.4 W is 28 hours of
a 3,000 mAh battery. Suspend is the lever for days. Taking cores offline
saved nothing: they're power-collapsed 95% of the time anyway, but
something wakes a core every millisecond (the sensors).

The gauge's `capacity` never updates after boot; `voltage_now` and
`current_now` are live. The gauge isn't sampled while suspended, so the
draw in s2idle itself needs a USB power meter.

### The display pipeline

With the backlight off, the MDP, DSI link and panel keep running at
60 Hz. Only a DRM master can sleep the panel, and the application's DRM
client holds master while it draws. The sequence that works:

1. Stop the DRM client (about 800 ms). fbdev restores the console on
   the last master close and turns the backlight on, so write `4` to
   `bl_power` right after.
2. Write `4` to `fb0/blank` (about 275 ms). DSI and MDP suspend, the
   CRTC goes inactive.
3. To wake: `0` to `fb0/blank` (about 600 ms), restart the client; its
   first frame followed about 120 ms later. Each unblank logs a DPU
   "vblank timeout" and recovers.

Blanking while a client holds master does nothing. With
`Fp3Extras.Console.release_panel/0` done, no fbcon flashes in step 1.

### The sensor streams

The ADSP streams the accelerometer at 200 Hz (the driver ignores a lower
rate) plus gyro, magnetometer and proximity into readers holding the IIO
devices open: about 250 interrupts and 1,200 cross-core wakeups a second.
`0` into each device's `buffer/enable` stops the stream while the readers
stay blocked; `1` resumes it. `Fp3Extras.Sleep.stop_sensors/1` does it.

### The BEAM

Eight schedulers make every wakeup a cross-core interrupt.
`schedulers_online` 2 while idle saved 75 mW; `+sbwt none` in `vm.args`
is the companion.

## Suspend to idle

`/sys/power/mem_sleep` offers `s2idle` only; `mem` into
`/sys/power/state` blocks until the resume. Wake sources: the power
button, the RTC alarm (`+N` into `/sys/class/rtc/rtc0/wakealarm`, `0` to
clear), the USB cable, the charger. Not: the touchscreen and volume keys
(no `wakeup-source` in the device tree), the modem, Wi-Fi without a
wake-on-wireless trigger. `Fp3Extras.Power.suspend(wake_after: 300)`
does the alarm and the write. The power button's press also arrives as
a key event after the wake.

The PMIC RTC reads 1970 and the kernel never sets it, which is fine for
a relative alarm.

## Around a suspend

* **Time stops.** `CLOCK_MONOTONIC` doesn't advance in s2idle, so
  Erlang's monotonic clock and every timer on it pause (a 10 s timer had
  8.5 s left after a 31 s suspend). `System.os_time/0` moves. The VM
  runs with `+C multi_time_warp`. `Fp3Extras.Sleep` reports both clocks.
* **Quiet the display first.** The one hang in a day of cycles came with
  the GPU mid-frame at suspend entry.
* **Kernel noise on resume.** The camera drivers print two WARN
  backtraces on every resume and the focus motor fails its I2C resume.
  Harmless, but drawn through fbcon at 65 ms a line they stalled the
  BEAM for 10 to 14 seconds; unbound, about 1 s.
  `Fp3Extras.Console.release_panel/0`.
* **Wi-Fi.** Without a wake-on-wireless trigger, taking `wlan0` down at
  suspend fails ("Failed to disable vif: -EIO"). wpa_supplicant
  reconnects within half a second on most wakes, eleven minutes once,
  and once never. `Fp3Extras.Sleep` waits for VintageNet and otherwise
  restarts the WCNSS remoteproc (`Fp3Extras.WiFi.reset/1`);
  `Fp3Extras.WiFi.PowerManager` lets VintageNet's watchdog do the same.
* **Wake on wireless.** With a trigger the association survives and the
  firmware answers ARP, neighbour discovery and rekeying.
  `Fp3Extras.WiFi.wake_on_wireless/2` sets it through `wpa_cli`. `:any`
  wakes on LAN chatter within seconds; `:magic_packet` stayed asleep
  through pings but didn't wake on a Wake-on-LAN frame in one test.
* **The modem** sits in its cold-boot low-power mode without an APN.
  Untested through suspend.
* **The screen** comes back as it was. Turn the backlight off before
  suspending.
* **The status LED** is driven by the PMIC, so a colour or an
  `hw_pattern` keeps going through suspend; the software `pattern`
  freezes.

## The sleep sequence

`Fp3Extras.Sleep.sleep/1`: the `:before` hook, stop sensors, release the
panel, suspend (with the alarm), restart sensors, the `:after` hook, wait
for Wi-Fi and reset it if needed.

`Fp3Extras.Screen`'s `suspend_after_ms` counts from the screen going
black and calls `:on_suspend` in its own process; the application puts
`sleep/1` there. If the screen is still black on return, the count
starts over, so a charger or alarm wake sleeps again; a power button wake
arrives as a tap that brightens the screen.

Open: the draw in s2idle itself, Venus and the cameras after many
cycles, and the remoteproc restart on a phone.
