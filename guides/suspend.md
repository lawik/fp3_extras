# Suspend, wake and power

Found on 2026-10-10 on nerves_system_fp3 v0.2.4 (kernel 6.19.5-msm8953),
with the phone reachable over SSH and Tailscale. The phone had died
overnight on battery with the screen off, which is what started this.
`Fp3Extras.Sleep` is the sleep sequence these notes add up to;
`Fp3Extras.Power`, `Fp3Extras.WiFi`, `Fp3Extras.Console` and
`Fp3Extras.Battery` are its parts.

## What the phone draws

Measured with the charger's USB input suspended so the fuel gauge sees
the system alone (`Fp3Extras.Battery.measure/2`; the module says why
charger current is no good). Idle, Wi-Fi and Tailscale up, no SIM:

| State | Draw |
|---|---|
| UI up, screen on at about half brightness | about 0.92 W |
| Backlight off, display pipeline still running | about 0.90 W |
| Plus the ADSP sensor streams stopped | about 0.76 W |
| Plus the BEAM on two schedulers | about 0.68 W |
| DRM client stopped and the display pipeline powered down, sensors running | about 0.60 W |

So the three things worth doing while awake: power the display pipeline
down (about 340 mW), stop the sensor streams (about 140 mW), and keep
the BEAM from waking every core (about 75 mW). Each is explained
below. Even all three together leave about 0.4 W, some 28 hours of a
3,000 mAh battery; suspend is the lever for days.

Taking CPU cores offline saved nothing measurable. The cores spend 95%
of the time power-collapsed anyway, and the clusters reach their
retention states; what they never reach is full cluster power collapse,
because something wakes a core every millisecond or so (see the
sensors).

The fuel gauge's `capacity` is the open-circuit estimate made at boot
and never updates on this kernel, so it can't drive a low-battery
warning. `voltage_now` and `current_now` are live; `current_avg` reads
0. The gauge also isn't sampled while the phone is suspended, so how
much s2idle itself draws is still unmeasured: a USB power meter inline
with the charger is the way to get that number.

### The display pipeline

With the backlight off, the MDP, the DSI link and the panel keep running
at 60 Hz and hold a constant memory-bandwidth vote; that's the 340 mW.
The panel driver has a proper sleep-in path, but only a DRM master can
trigger it, and the application's DRM client holds master while it
draws. A client with a DPMS call could do it directly; Emerge 0.4.2, the
one these numbers come from, has none yet (asked for). Without one, the
panel blank (`Fp3Extras.Panel`) is the lever while awake, and this is
the sequence that works, timed on the phone:

1. Stop the DRM client (with Emerge, its viewport): about 800 ms. The
   kernel's fbdev emulation restores the console on the panel when the
   last DRM master closes, and turns the backlight on, so write `4` to
   `bl_power` right after.
2. Write `4` to `/sys/class/graphics/fb0/blank`: about 275 ms. The DSI
   and display controller suspend, the CRTC goes inactive, the vsync
   interrupt stops.
3. To wake: write `0` to `fb0/blank` (about 600 ms), restart the DRM
   client; Emerge's first frame was on the panel about 120 ms later.
   Each unblank logs a DPU "vblank timeout" error; it recovered every
   time.

Blanking fb0 while a DRM client holds master does nothing, as the fb
helper defers to the userspace master (seen with Emerge running).
Restarting the client without the unblank, letting its own modeset
re-enable the CRTC, wasn't tried and might save the 600 ms. With
`Fp3Extras.Console.release_panel/0` done, there's no fbcon to flash in
step 1 either.

All of this is for staying awake with the screen dark. Suspend to idle
takes the display down anyway, with or without the blank.

### The sensor streams

The ADSP streams the accelerometer at 200 Hz (the IIO
`sampling_frequency` accepts a lower value and ignores it: the driver
always asks for the sensor's maximum rate, one report per sample), and
the gyro, magnetometer and proximity sensor alongside, into readers
that hold the IIO devices open (`ex_qcom_smgr`). That's about 250
interrupts a second on the ADSP link and, through the BEAM waking its
dirty IO threads for each sample, some 1,200 cross-core wakeups a
second. Writing `0` to each device's `buffer/enable` stops the stream
at the ADSP while the readers stay blocked on their open file; `1`
resumes it on the same descriptor, and the next sample arrives within a
second. No process is touched. `Fp3Extras.Sleep.stop_sensors/1` does
it. The accelerometer alone is most of the traffic, so a phone that
watches its orientation and nothing else should still stop the other
three.

### The BEAM

With eight schedulers, every wakeup is a cross-core interrupt. Setting
`schedulers_online` to 2 while idle saved about 75 mW; `+sbwt none` in
`vm.args` (no busy waiting) is the companion setting. The phone ran with
both for these measurements.

## Suspend to idle

`/sys/power/mem_sleep` offers `s2idle` only; `echo mem >
/sys/power/state` enters it, and the write blocks until the resume.
Twenty-odd cycles were done; all but one came back. The clusters stay
in their idle states and the devices suspend; there's no firmware
"system suspend" on this SoC.

Wake sources that worked: the power button, the RTC alarm (`echo +N >
/sys/class/rtc/rtc0/wakealarm`, clear a pending one with `0` first),
the USB cable and the charger. Not wake-capable: the touchscreen and the
volume keys (no `wakeup-source` on their device tree nodes), the modem,
and Wi-Fi without a wake-on-wireless trigger (below). Touch wake would
be a device tree change plus a check that the Himax controller keeps
its interrupt alive asleep.

`Fp3Extras.Power.suspend(wake_after: 300)` does the alarm and the
write and clears the alarm after. The power button's press is also
delivered to the application as a key event after the wake, so a
`Fp3Extras.Buttons` `on_power_tap` fires; decide there whether a wake
should toggle the screen.

The PMIC RTC isn't set to real time (it reads 1970 plus a few hours),
the kernel neither reads nor writes it, and the pm8941-rtc node lacks
`allow-set-time`, so nerves_time can't use it. That's fine for the
alarm, which is relative to the RTC's own time.

## What happens around a suspend

* **Time stops.** The kernel's `CLOCK_MONOTONIC` doesn't advance in
  s2idle, so Erlang's monotonic clock and every timer built on it
  (`Process.send_after/3`, `:timer`, GenServer timeouts) pause for the
  whole suspend and resume where they were. Measured: a 10 s timer had
  8.5 s left after a 31 s suspend. `System.os_time/0` is wall time and
  does move (the arch timer keeps counting through s2idle, so the
  kernel knows how long it was gone). Read it before and after for
  anything that needs the real elapsed time, and expect
  `:erlang.monotonic_time/0` and `os_time` to disagree by the suspended
  total afterwards. The VM runs with `+C multi_time_warp`, so the OS
  time jump is handled. `Fp3Extras.Sleep` reports both clocks.
* **Quiet the display first.** The one hang in a day of cycles came
  with the GPU mid-frame at suspend entry: the hangcheck fired as
  userspace was being frozen and the phone never printed another line.
  It may have been a GPU bug in the firmware of the day rather than
  suspend's fault; either way, blanking before suspending costs nothing
  and leaves nothing in flight. That cycle's suspend entry also spent
  10 s in the filesystem sync.
* **Kernel noise on resume.** The camera drivers (the sensor drivers'
  runtime PM, after the system resume powered them down already) print
  two WARN backtraces on every resume, and the rear camera's focus
  motor fails its resume over I2C. Harmless, but with `console=tty0
  loglevel=8` and the framebuffer console bound they're drawn on the
  panel through fbcon, rotated, in a 16x32 font, at about 65 ms a line,
  and that drawing stalled the BEAM for 10 to 14 seconds. With fbcon
  unbound: about 1.5 s with `loglevel=8` (the serial port draining the
  same text), about 1 s with the console log level at 3, which is the
  suspend transit itself. `Fp3Extras.Console.release_panel/0` is the
  fix that keeps the messages: they still go to `dmesg`, RingLogger and
  the serial port, only the drawing stops. Removing `console=tty0`
  from the kernel command line would do the same system-wide, at the
  cost of the on-panel boot log for everyone.
* **Wi-Fi.** Without a wake-on-wireless trigger, mac80211 takes `wlan0`
  down at suspend entry and wcn36xx's command to the firmware fails
  ("Failed to disable vif: -EIO"). After the resume wpa_supplicant
  reconnects on its own: within half a second on most wakes, eleven
  minutes once, and once not at all until the phone was rebooted.
  That's wpa_supplicant backing off against a firmware that answers
  scans badly, and a reconfigure doesn't help when the firmware is
  stuck. `Fp3Extras.Sleep` waits for VintageNet to report the
  connection and otherwise restarts the WCNSS remoteproc
  (`Fp3Extras.WiFi.reset/1`), which reloads the firmware;
  `Fp3Extras.WiFi.PowerManager` lets VintageNet's watchdog do the same
  whenever the link is down for too long. The driver bug belongs in
  the kernel fork. Tailscale came back with the link every time.
* **Wake on wireless.** wcn36xx supports it: with a trigger configured
  the interface stays associated through the suspend, the firmware
  answers ARP and neighbour discovery and handles group rekeying, and
  the EIO above doesn't happen. `Fp3Extras.WiFi.wake_on_wireless/2`
  sets the trigger through wpa_supplicant (`wpa_cli set
  wowlan_triggers`; there's no `iw` in the system). `:any` worked as
  advertised and is useless on a LAN: Tailscale, mDNS and friends woke
  the phone within a second or two every time. `:magic_packet` kept
  the phone asleep through pings, as it should, but a Wake-on-LAN
  frame didn't wake it in the one test, and the association was gone
  after the alarm wake. Not pursued further.
* **The modem.** With no APN configured nothing puts it online, so it
  sits in its cold-boot low-power mode, unregistered. It isn't a drain
  and wasn't tested through suspend.
* **The screen.** The panel and backlight come back as they were. Turn
  the backlight off before suspending if the screen should be dark on
  wake, and let the wake source decide whether to turn it on.
* **The status LED.** The RGB LED is driven by the PMIC (`rgb:status`
  under `/sys/class/leds`, `multi_intensity` and `brightness`), so a
  colour set before a suspend stays lit through it, and a pattern does
  too: with the `pattern` trigger, `hw_pattern` takes steps of
  `brightness ms brightness 0` (all of one length, so a blink is
  `0 500 0 0 255 500 255 0`) and the PMIC plays them from its own
  memory with the CPU asleep. On nerves_system_fp3 v0.3.0 the trigger is
  a module (`modprobe ledtrig-pattern`) and `hw_pattern` is refused
  until `-1` is written to `repeat`, a kernel bug; the next system has
  both fixed. The software `pattern` attribute runs on a kernel timer
  and freezes for the suspend.

## The sleep sequence

`Fp3Extras.Sleep.sleep/1`, in order:

1. The application's `:before` hook: display off, rendering stopped.
2. Stop the sensor streams.
3. Take the kernel console off the panel (idempotent).
4. Suspend, with the RTC alarm when asked, noting the wakeup sources
   before and after to say what woke the phone.
5. Restart the sensor streams.
6. The application's `:after` hook.
7. Wait for Wi-Fi; restart its firmware if it doesn't come back.

A policy on top, the simple half of which `Fp3Extras.Screen` now
provides: its `suspend_after_ms` setting counts from the screen going
black (so nothing holds the phone awake; `keep_awake/1` keeps the screen
on), and when it runs out the `:on_suspend` function is called in a
process of its own. The application puts `sleep/1` there. When the
function returns with the screen still black, the count starts over, so
a charger or alarm wake goes back to sleep after the same time, and a
power button wake arrives as a tap that brightens the screen. The other
half, an RTC wake every few minutes to do what's due, is the
application's choice of `:wake_after` and what it does in the `:after`
hook; nothing needs it yet.

Open: how much s2idle itself draws (the gauge can't say), whether the
Venus and camera drivers behave after many cycles, and the remoteproc
restart, which has been written but not yet run on the phone.
