# Suspend, wake and power

Found on 2026-10-10 on nerves_system_fp3 v0.2.4 (kernel 6.19.5-msm8953),
with the phone reachable over SSH. The phone had died overnight on
battery with the screen off, which is what started this.

## What the phone draws

Measured with the charger's USB input suspended so the fuel gauge sees
the system alone (`Fairphone3Extras.Battery.measure/2`; see the module
for why charger current is no good):

| State | Draw |
|---|---|
| Idle, UI up, screen on at 60% | about 0.92 W |
| Backlight off | about 0.90 W |
| Plus the ADSP sensor streams stopped (`buffer/enable=0` for accel, gyro, mag, prox) | about 0.76 W |
| Plus the BEAM on two schedulers (`schedulers_online=2`) | about 0.68 W |

Taking CPU cores offline saved nothing measurable; the cluster idles
well on its own. The sensors cost about 140 mW together, so a phone that
isn't watching its orientation should stop them. Even so, 0.7 W empties
a 3,000 mAh battery in about 16 hours. Suspend is the lever that
matters.

The fuel gauge's `capacity` is the open-circuit estimate made at boot
and never updates on this kernel, so it can't drive a low-battery
warning. `voltage_now` and `current_now` are live.

## Suspend to idle

`/sys/power/mem_sleep` offers `s2idle` only; `echo mem >
/sys/power/state` enters it, and the write blocks until the resume.
Wake sources that worked:

* the power button
* the RTC alarm: `echo +N > /sys/class/rtc/rtc0/wakealarm` for N seconds
  from now (clear a pending alarm with `0` first)
* USB: the cable, the charger

`Fairphone3Extras.Power.suspend(wake_after: 300)` does the alarm and the
write and clears the alarm after.

## What happens around a suspend

* **Time stops.** The kernel's `CLOCK_MONOTONIC` doesn't advance in
  s2idle, so Erlang's monotonic clock and every timer built on it
  (`Process.send_after/3`, `:timer`, GenServer timeouts) pause for the
  whole suspend and resume where they were. A timer due in a minute
  fires after a minute of awake time. `System.os_time/0` is wall time
  and does move; read it before and after for anything that needs the
  real elapsed time, and expect `:erlang.monotonic_time/0` and
  `os_time` to disagree by the suspended total afterwards (the VM runs
  with `+C multi_time_warp`, so OS time corrections are handled).
* **Kernel noise on resume.** The camera drivers (camss, the sensor
  drivers) print two WARN backtraces on every resume. Harmless, but with
  `console=tty0 loglevel=8` and the framebuffer console bound they're
  drawn on the panel through fbcon, and that drawing stalled the BEAM
  for about ten seconds. Unbinding fbcon, or a console log level of 3,
  brings it to about a second. Do one of them before suspending
  (`Fairphone3Extras.Console`).
* **Wi-Fi after resume.** wcn36xx sometimes fails to come back ("Failed
  to disable vif: -EIO" in the log) and the interface stays down for
  minutes until VintageNet's retries get through. Count on being
  offline for a while after a wake.
* **Wake on wireless.** `wpa_cli set wowlan_triggers any` keeps the
  association through suspend and wakes the phone on any unicast frame,
  which on a normal LAN is every few seconds: too chatty to be useful.
  `magic_packet` did not wake the phone in the one test made. Not
  pursued further.
* **The screen.** The panel and backlight come back as they were. Turn
  the backlight off before suspending if the screen should be dark on
  wake, and let the wake source decide whether to turn it on.

## A sleep policy, sketched

Not built yet; this is where the findings point:

1. Screen off for a while, nothing keeping the phone awake
   (`Fairphone3Extras.Screen.keep_awake/1` is the hook) → stop the sensor
   streams, then suspend with an RTC wake every few minutes.
2. On each wake: check the time, do what's due (fetch, sync), suspend
   again unless the power button or USB woke it.
3. The power button wakes to the UI; the screen fades up from black.

Open questions: how much s2idle actually saves on this SoC (the
measurement was never made; the sensor and scheduler numbers above are
awake numbers), whether the modem stays registered through it, and
whether the Venus and camera drivers behave after many cycles.
