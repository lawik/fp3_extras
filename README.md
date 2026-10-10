# Fp3Extras

The Fairphone 3's hardware from Elixir on Nerves
([`nerves_system_fp3`](https://github.com/mlainez/nerves_system_fp3)), in
small modules that each do one thing and know nothing about the
application around them. Lifted out of a phone UI; what's here is the
part that touched sysfs, ALSA, evdev and the sensors, and what was
learned doing it.

| Module | What |
|---|---|
| `Fp3Extras.Backlight` | The panel's backlight: percent on a 2.2 power curve, raw, power on/off |
| `Fp3Extras.Panel` | Power the panel and display pipeline down through fbdev's `blank` (untested on the FP3; see the module) |
| `Fp3Extras.Screen` | On, dim, off with fades; touch and power-button handling; keep-awake; automatic brightness |
| `Fp3Extras.Console` | Take the kernel's framebuffer console off the panel; lower the console log level |
| `Fp3Extras.Volume` | Volume in steps through an ALSA softvol control, saved across reboots |
| `Fp3Extras.Buttons` | Volume up/down, a power tap, and touch activity, from evdev |
| `Fp3Extras.Power` | Suspend to idle with an RTC wake, and what to expect after |
| `Fp3Extras.Sleep` | The whole sleep: quiet the sensors and the console, suspend, restore, get Wi-Fi back |
| `Fp3Extras.WiFi` | Wi-Fi after a suspend: wait, restart the firmware, wake on wireless; a VintageNet power manager |
| `Fp3Extras.Battery` | The fuel gauge, charger and USB-C mode; a rough time-left estimate; measuring the system's draw |
| `Fp3Extras.Orientation` | Portrait or landscape from the accelerometer, with the FP3's axes |
| `Fp3Extras.LightSensor` | Ambient light from the front camera (the FP3 has no light sensor) |
| `Fp3Extras.Mic` | The two mics: the bottom one by default, the top one as a second channel |
| `Fp3Extras.Leds` | The RGB notification LED and the two white flash LEDs (torch mode) through `/sys/class/leds` |
| `Fp3Extras.Vibrator` | The vibration motor, through the Nerves system's `rumble` tool: single buzzes and blocking patterns |
| `Fp3Extras.Fingerprint` | Experiment: the fingerprint sensor's GPIO lines (dead end, documented) |
| `Fp3Extras.TEE.QSEECom` | Experiment: talking to TrustZone's Keymaster through a kernel shim |

The guides hold the hardware notes:

* [Hardware](guides/hardware.md): what's in the phone and where Linux
  exposes it; boot, partitions, radios, cameras, video decode.
* [Display](guides/display.md): DRM on the Adreno 506, the console,
  backlight ranges and curves, orientation.
* [Suspend](guides/suspend.md): s2idle, wake sources, timers, Wi-Fi,
  power numbers.
* [Audio](guides/audio.md): the routing, the softvol trick, the two mics
  and the kernel crash.

Hardware-accelerated video playback isn't in here. It lives in
[`membrane_v4l2_decoder`](https://github.com/lawik/membrane_v4l2_decoder):
a Membrane element with a Rust NIF that drives the Venus decoder through
V4L2 and hands frames as DMA-BUFs, without a copy, to a video target
that accepts them (Emerge's `Membrane.VideoInterop.Sink` is the one it
was written against). It's
generic V4L2 with two Venus workarounds; the hardware guide says how it
fits.

## Installation

```elixir
def deps do
  [
    {:fp3_extras, github: "lawik/fp3_extras", targets: @all_targets},
    # Add what the modules you start need (see below):
    {:input_event, "~> 1.4", targets: @all_targets},
    {:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr", targets: @all_targets},
    {:fp3_camera, github: "mlainez/fp3_camera", targets: @all_targets}
  ]
end
```

Nothing in this library is a hard dependency. Each module calls the
library it needs only when it's loaded, so the library compiles and tests
on a laptop and a firmware adds what it uses:

| Module | Needs |
|---|---|
| `Buttons` | `input_event` |
| `Orientation` | `ex_qcom_smgr` (ADSP sensors) |
| `LightSensor` | `fp3_camera` |
| `Fingerprint` | `circuits_gpio` |
| `Sleep`, `WiFi` | `vintage_net` for the Wi-Fi wait and the power manager; `wpa_cli`, which the system has |
| `Volume`, `Mic` | `ex_audio` (a real dependency; it sets mixer controls with the system's `amixer`) |

Everything that keeps something across reboots writes under one
directory:

```elixir
config :fp3_extras, state_dir: "/data/phone"
```

## A phone's supervision tree

```elixir
children = [
  Fp3Extras.Volume,
  Fp3Extras.Mic,
  {Fp3Extras.Screen,
   notify: &MyPhone.UI.display_changed/1,
   defaults: [brightness: 60, dim_after_ms: 30_000, off_after_ms: 60_000]},
  {Fp3Extras.Orientation, notify: &MyPhone.UI.orientation_changed/1},
  {Fp3Extras.Buttons,
   on_touch: &Fp3Extras.Screen.touch/0,
   on_power_tap: &Fp3Extras.Screen.toggle/0,
   on_volume: fn
     :up -> Fp3Extras.Volume.up()
     :down -> Fp3Extras.Volume.down()
   end},
  MyPhone.UI,
  # Once the UI owns the panel, stop the kernel drawing on it.
  {Task, &Fp3Extras.Console.release_panel/0}
]
```

And when the screen has been off for a while and nothing holds the phone
awake, a sleep with a timed wake, the UI blanked around it:

```elixir
{:ok, wake} =
  Fp3Extras.Sleep.sleep(
    wake_after: 600,
    before: &MyPhone.UI.blank/0,
    after: fn _ -> :ok end
  )

# wake.woke_by: :rtc means do what's due and sleep again;
# :pwrkey or :usb means someone wants the phone.
```

With `Fp3Extras.WiFi.PowerManager` in `config :vintage_net,
power_managers: [...]`, VintageNet restarts the Wi-Fi firmware on its
own whenever the link is down for too long.

The firmware's `rootfs_overlay/etc/asound.conf` wants the softvol device
from `Fp3Extras.Volume.asound_conf/0` and the hook from
`Fp3Extras.Mic.asound_conf_hook/0`; `priv/asound.conf` has both.

## Running on a laptop

Every module runs without the hardware: reads return `{:error, ...}` or
nil, writes do nothing, and the GenServers track their state (the
`Screen` fades its levels, the `Volume` keeps its level) so a UI can be
developed with the same code. `mix test` exercises them against
directories of files standing in for sysfs and a fake `amixer` that
ex_audio is pointed at.
