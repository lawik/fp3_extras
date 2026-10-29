# The Fairphone 3 under Nerves

What's in the phone and where Linux exposes it.

## The platform

* **SoC:** Snapdragon 632 (`sdm632`, msm8953 family): eight Kryo 250
  cores, Adreno 506 GPU, Venus video core, Hexagon ADSP (audio,
  sensors), modem DSP, WCNSS wireless.
* **PMICs:** PM8953 and PMI632. The PMI632 has the charger, the QGauge
  fuel gauge, the backlight driver, the LEDs, the vibrator and the power
  key.
* **Device tree:** `sdm632-fairphone-fp3.dtb`, covering the 3 and 3+;
  the system applies overlays for the fitted camera and loudspeaker
  modules.
* **Bootloader:** stock LK with lk2nd on `boot`, reading `extlinux.conf`
  from the Nerves boot partition. Kernel arguments:

  ```
  earlycon console=ttyMSM0,115200 console=tty0 loglevel=8 fbcon=rotate:3
  fbcon=font:TER16x32 rootfs=/dev/mmcblk0p62p2 bootpart=/dev/mmcblk0p62p1
  rootfstype=squashfs ro rootwait panic=30
  ```

  `console=tty0 loglevel=8` draws every kernel message on the panel; see
  `Fp3Extras.Console`.
* **Storage:** Nerves lives in Android's `userdata` (`/dev/mmcblk0p62`),
  partitioned again: p1 boot, p2 rootfs (squashfs), p3 data (F2FS) at
  `/root`, with `/data` a symlink. A first-boot step grows p3 to fill
  `userdata`. `/sys/fs/pstore` holds the last panic.
* **Hostname:** `nerves-XXXX` from the Wi-Fi MAC's last four characters,
  advertised over mDNS.

## Libraries for the hardware

All from [mlainez](https://github.com/mlainez), started at boot:

| Library | Hardware |
|---|---|
| `ex_rmtfs`, `ex_remoteproc`, `ex_qbootctl` | Modem storage, DSP start-up, boot slots |
| `ex_qcom_smgr` | ADSP sensors: accelerometer, gyroscope, magnetometer, pressure, proximity |
| `ex_audio` | ALSA routing at boot, mixer controls |
| `fp3_camera` | Stills, H.264 streams, raw statistics |
| `fp3_modem`, `vintage_net_qmi`, `qmi` | Cellular data |
| `ex_nfc`, `ex_location`, `blue_heron` | NFC, GPS, Bluetooth LE (`hci0`, exclusive) |
| `nerves_ai` | Nx on the CPU, YOLO, Whisper, small LLMs; the first-boot resize |

[`nerves_livebook_fp3`](https://github.com/mlainez/nerves_livebook_fp3)
has a notebook per subsystem. This library covers what the above don't:
plain sysfs, ALSA and evdev.

## LEDs and the vibrator

The RGB notification LED is a multicolor LED on the PMIC's LPG:
`multi_intensity` takes red, green, blue; `brightness` scales all three.
The two white flash LEDs are on the flash controller; `brightness` is
torch mode, no timeout, hot. Names: `rgb:status` (`max_brightness` 255),
`white:flash-0`, `white:flash-1`.

The LPG also plays patterns itself: up to 64 levels in the PMIC's SDAM,
stepped by its PBS sequencer every so many ms (8 ms units, up to 511 ms,
one length for all steps), with the CPU asleep and through suspend. The
kernel's `pattern` trigger exposes it as `hw_pattern` in the
"level ms level 0" form (holds; the LPG can't fade). All lit channels play
the same table, so only full colours keep their hue. The trigger's
software `pattern` steps `brightness` on a kernel timer: any colour and
timing, stops in suspend. `Fp3Extras.Leds.pattern/3` picks.

The vibrator is the PMI632's `pm8xxx-vibrator`, a force-feedback input
device, so the system ships `rumble [-d DEV] MS [STRENGTH]` (1 to
10,000 ms, strength 1 to 65,535), which returns when the rumble is over.
`Fp3Extras.Vibrator` wraps it.

## sysfs paths

| Path | What |
|---|---|
| `/sys/class/backlight/*/` | `brightness` 0..4095, `bl_power` 0/4 |
| `/sys/class/graphics/fb0/blank` | `4` powers the panel down, `0` up; no effect while a DRM client holds the display |
| `/sys/class/leds/*/` | `rgb:status` (`multi_intensity`, `brightness`, `hw_pattern`, `pattern`), `white:flash-0/1` |
| `/sys/class/vtconsole/vtcon*/bind` | The framebuffer console |
| `/proc/sys/kernel/printk` | Console log level |
| `/sys/class/power_supply/qg-battery/` | `voltage_now`, `current_now` (µV, µA, negative discharging), `capacity` (boot-time only), `status`, `temp`, `health`, `technology`, `charge_full_design` |
| `/sys/class/power_supply/pmi632-charger/` | `online`; `status` writable: `0` suspends USB input, `1` resumes |
| `/sys/class/power_supply/tcpm-source-psy-*/` | `usb_type` brackets the active USB-C mode |
| `/sys/power/state`, `/sys/power/mem_sleep` | `mem` is s2idle |
| `/sys/class/rtc/rtc0/wakealarm` | `+N` wakes in N seconds |
| `/sys/class/wakeup/*/` | Wakeup sources and event counts |
| `/sys/bus/iio/devices/iio:device*/buffer/enable` | The ADSP sensor streams |
| `/sys/class/remoteproc/*/state` | `a204000.remoteproc` is WCNSS (Wi-Fi) |
| `/dev/input/event*` | gpio-keys, pm8xxx-pwrkey, the touchscreen, the headset jack |
| `/dev/dri/card0` | The msm display controller (`card1` is the GPU's) |
| `/dev/video0`, `/dev/video1` | Venus decoder and encoder (numbers can move) |
| `/dev/gpiochip0` | SoC GPIOs. 135-138 are TrustZone's: don't touch |

## Wi-Fi

WCNSS is the WCN3680's core (Wi-Fi and Bluetooth), its firmware
`wcnss.mbn` loaded by remoteproc as `a204000.remoteproc`; the kernel
driver is the mainline `wcn36xx`. The MAC (`02:00:c2:…`, locally
administered) survives a firmware restart.

After many hours up the firmware can stop transmitting. Scans still find
the access point, strong and close, but every authentication times out:

```
wlan0: send auth to 60:45:cb:8b:bf:a0 (try 3/3)
wlan0: authentication with 60:45:cb:8b:bf:a0 timed out
wcn36xx: ERROR Failed to flush hardware tx queues
```

Later in the same episode the last line became `wcn36xx: ERROR
SMD_EVENT (312) not supported`, an event the driver doesn't know. An
access point answers authentication before any key is checked, so the
frames never got on the air. The remoteproc still reads `running`, so
the kernel's crash recovery never runs, and wpa_supplicant retries
forever.

`stop` then `start` into the remoteproc's `state` fixes it: the stop
blocks about 20 s (`No SMD response to req 127 in 10000ms`, then the same
for `hal_stop`), the start takes under a second, and `wlan0`
authenticates on the first frame 14 s later, with a DHCP lease 15 s
after that and VintageNet reconnecting by itself. Bluetooth restarts with
it. `Fp3Extras.WiFi.Watchdog` does this when the signs line up. What
starts the jam is unknown; candidates are the firmware's power save, a
roam or band change, a suspend, or the host and firmware disagreeing on
the API.

## Video decode

Venus decodes H.264, VP8, VP9, HEVC, VC-1, MPEG-2/4 and H.263 up to
4096x4096 through a V4L2 stateful m2m device, outputting NV12.
`membrane_v4l2_decoder` drives it: a Rust worker thread owns the device,
exports each CAPTURE buffer once as a DMA-BUF and leases frames
downstream as `%VideoInterop.Frame{}`, with no copy. About 150 fps at
1080p, bit-exact with FFmpeg's software decoder. Two Venus quirks it
handles: after `V4L2_DEC_CMD_STOP` the driver never flags the last buffer
or raises EOS, and the 1080p compose rectangle is the full 1088 lines.

A playback pipeline, with Emerge as the video target:

```
MP4 source -+-> H264.Parser -> V4L2.H264.Decoder -> Pacer -> VideoInterop.Sink
            +-> AAC.Parser -> AAC.FDK.Decoder -> AudioGate -> PortAudio.Sink
```

The pacer releases frames at their pts, the gate holds sound until the
first frame is ready, and the picture is held back by the sound card's
output latency.

## Building natives

Rust NIFs cross-compile with the Nerves toolchain: map the `CC` triple to
a Rust target (`aarch64-nerves-linux-gnu` to `aarch64-unknown-linux-gnu`),
set `CARGO_TARGET_<T>_LINKER` and
`RUSTFLAGS=-C link-arg=--sysroot=$NERVES_SDK_SYSROOT`. On a Mac, Bundlex
needs the toolchain's `ar` first on `PATH`, as Apple's drops Linux objects.

## Flashing

Fastboot mode: power off, hold Volume Down, plug in USB. A `devinfo`
partition with the unlocked flag set, a dummy `dtbo`, lk2nd on `boot`,
the Nerves image on `userdata`. After that, `mix upload`.
