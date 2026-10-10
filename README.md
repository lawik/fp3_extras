# Fairphone3Extras

The Fairphone 3's hardware from Elixir on Nerves
([`nerves_system_fp3`](https://github.com/mlainez/nerves_system_fp3)), in
small modules that each do one thing and know nothing about the
application around them. Lifted out of a phone UI; what's here is the
part that touched sysfs, ALSA, evdev and the sensors, and what was
learned doing it.

| Module | What |
|---|---|
| `Fairphone3Extras.Backlight` | The panel's backlight: percent on a 2.2 power curve, raw, power on/off |
| `Fairphone3Extras.Screen` | On, dim, off with fades; touch and power-button handling; keep-awake; automatic brightness |
| `Fairphone3Extras.Console` | Take the kernel's framebuffer console off the panel; lower the console log level |
| `Fairphone3Extras.Volume` | Volume in steps through an ALSA softvol control, saved across reboots |
| `Fairphone3Extras.Buttons` | Volume up/down, a power tap, and touch activity, from evdev |
| `Fairphone3Extras.Power` | Suspend to idle with an RTC wake, and what to expect after |
| `Fairphone3Extras.Battery` | The fuel gauge and charger; measuring the system's draw |
| `Fairphone3Extras.Orientation` | Portrait or landscape from the accelerometer, with the FP3's axes |
| `Fairphone3Extras.LightSensor` | Ambient light from the front camera (the FP3 has no light sensor) |
| `Fairphone3Extras.Mic` | The two mics: the bottom one by default, the top one as a second channel |
| `Fairphone3Extras.Fingerprint` | Experiment: the fingerprint sensor's GPIO lines (dead end, documented) |
| `Fairphone3Extras.TEE.QSEECom` | Experiment: talking to TrustZone's Keymaster through a kernel shim |

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
V4L2 and hands frames to Emerge as DMA-BUFs, without a copy. It's
generic V4L2 with two Venus workarounds; the hardware guide says how it
fits.

## Installation

```elixir
def deps do
  [
    {:fairphone3_extras, github: "lawik/fairphone3_extras", targets: @all_targets},
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
| `Volume`, `Mic` | `amixer`, which the Nerves system has |

Everything that keeps something across reboots writes under one
directory:

```elixir
config :fairphone3_extras, state_dir: "/data/phone"
```

## A phone's supervision tree

```elixir
children = [
  Fairphone3Extras.Volume,
  Fairphone3Extras.Mic,
  {Fairphone3Extras.Screen,
   notify: &MyPhone.UI.display_changed/1,
   defaults: [brightness: 60, dim_after_ms: 30_000, off_after_ms: 60_000]},
  {Fairphone3Extras.Orientation, notify: &MyPhone.UI.orientation_changed/1},
  {Fairphone3Extras.Buttons,
   on_touch: &Fairphone3Extras.Screen.touch/0,
   on_power_tap: &Fairphone3Extras.Screen.toggle/0,
   on_volume: fn
     :up -> Fairphone3Extras.Volume.up()
     :down -> Fairphone3Extras.Volume.down()
   end},
  MyPhone.UI,
  # Once the UI owns the panel, stop the kernel drawing on it.
  {Task, &Fairphone3Extras.Console.release_panel/0}
]
```

The firmware's `rootfs_overlay/etc/asound.conf` wants the softvol device
from `Fairphone3Extras.Volume.asound_conf/0` and the hook from
`Fairphone3Extras.Mic.asound_conf_hook/0`; `priv/asound.conf` has both.

## Running on a laptop

Every module runs without the hardware: reads return `{:error, ...}` or
nil, writes do nothing, and the GenServers track their state (the
`Screen` fades its levels, the `Volume` keeps its level) so a UI can be
developed with the same code. `mix test` exercises them against
directories of files standing in for sysfs and a fake `amixer`.
