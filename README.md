# Fp3Extras

The Fairphone 3's hardware from Elixir on Nerves
([`nerves_system_fp3`](https://github.com/mlainez/nerves_system_fp3)):
small modules that each do one thing and know nothing about the
application around them.

| Module | What |
|---|---|
| `Fp3Extras.Backlight` | Backlight in percent on a 2.2 curve, raw, power on/off |
| `Fp3Extras.Panel` | Power the display pipeline down through fbdev's `blank` |
| `Fp3Extras.Screen` | On, dim, off with fades; touch and power button; keep-awake; auto brightness; suspend timer |
| `Fp3Extras.Console` | Take the kernel console off the panel; console log level |
| `Fp3Extras.Volume` | Volume in steps through an ALSA softvol control, saved |
| `Fp3Extras.Mic` | The bottom mic, or both as two channels |
| `Fp3Extras.Buttons` | Volume up/down, power tap, touch activity from evdev |
| `Fp3Extras.Power` | Suspend to idle with an RTC wake |
| `Fp3Extras.Sleep` | The whole sleep: sensors, console, suspend, restore, Wi-Fi |
| `Fp3Extras.WiFi` | Wi-Fi after a suspend: wait, firmware restart, wake on wireless; a VintageNet power manager |
| `Fp3Extras.WiFi.Watchdog` | Restarts the Wi-Fi firmware when it stops transmitting while the network is in range |
| `Fp3Extras.Battery` | Fuel gauge, charger, USB-C mode; time left; measuring the system's draw |
| `Fp3Extras.Orientation` | Portrait or landscape from the accelerometer |
| `Fp3Extras.LightSensor` | Ambient light from the front camera |
| `Fp3Extras.Leds` | The RGB notification LED, with patterns the PMIC plays through suspend; the flash LEDs as a torch |
| `Fp3Extras.Vibrator` | The vibration motor through the system's `rumble` tool |
| `Fp3Extras.Fingerprint` | Experiment: the fingerprint sensor's GPIO lines (dead end) |
| `Fp3Extras.TEE.QSEECom` | Experiment: TrustZone's Keymaster through a kernel shim |

Guides: [hardware](guides/hardware.md), [display](guides/display.md),
[suspend](guides/suspend.md), [audio](guides/audio.md).

Hardware video decode is
[`membrane_v4l2_decoder`](https://github.com/lawik/membrane_v4l2_decoder):
a Membrane element with a Rust NIF driving the Venus decoder through V4L2,
handing frames on as DMA-BUFs.

## Installation

```elixir
{:fp3_extras, github: "lawik/fp3_extras", targets: @all_targets},
# Plus what the modules you start need:
{:input_event, "~> 1.4", targets: @all_targets},
{:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr", targets: @all_targets},
{:fp3_camera, github: "mlainez/fp3_camera", targets: @all_targets}
```

Only `ex_audio` is a hard dependency; the rest are called when loaded:

| Module | Needs |
|---|---|
| `Buttons` | `input_event` |
| `Orientation` | `ex_qcom_smgr` |
| `LightSensor` | `fp3_camera` |
| `Fingerprint` | `circuits_gpio` |
| `Sleep`, `WiFi`, `WiFi.Watchdog` | `vintage_net`; the system's `wpa_cli` |
| `Volume`, `Mic` | `ex_audio` |

State across reboots goes under one directory:

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
   on_suspend: fn -> Fp3Extras.Sleep.sleep(before: &MyPhone.UI.blank/0) end,
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
  {Task, &Fp3Extras.Console.release_panel/0}
]
```

`Fp3Extras.WiFi.PowerManager` in `config :vintage_net, power_managers:`
lets VintageNet restart the Wi-Fi firmware when the link stays down.

The firmware's `rootfs_overlay/etc/asound.conf` needs the softvol device
from `Fp3Extras.Volume.asound_conf/0` and the hook from
`Fp3Extras.Mic.asound_conf_hook/0`; `priv/asound.conf` has both.

## On a laptop

Every module runs without the hardware: reads return errors or nil,
writes do nothing, and the GenServers track their state. `mix test`
runs against directories standing in for sysfs and a fake `amixer`.
