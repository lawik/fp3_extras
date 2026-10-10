# The Fairphone 3 under Nerves

What's in the phone, where Linux exposes it, and what was found working
with it from Elixir on `nerves_system_fp3` v0.2.4 (kernel 6.19.5,
Buildroot). Dates are when something was measured; a later system may
differ.

## The platform

* **SoC:** Qualcomm Snapdragon 632 (msm8953 family, `sdm632`). Eight
  Kryo 250 cores, Adreno 506 GPU, Venus video core, Hexagon ADSP (audio,
  sensors), a modem DSP (MPSS) and the WCNSS wireless subsystem.
* **PMICs:** PM8953 and PMI632. The PMI632 has the charger (`qcom_smbx`),
  the QGauge fuel gauge, the backlight LED driver and the power key.
* **Device tree:** `sdm632-fairphone-fp3.dtb`. One tree covers the
  Fairphone 3 and 3+; the system identifies the fitted camera and
  loudspeaker modules at boot and applies overlays. `/proc/device-tree/model`
  reads "Fairphone 3".
* **Bootloader:** the stock LK, with lk2nd installed on `boot` as a
  second stage that reads `extlinux.conf` from the Nerves boot partition.
  The boot arguments are

  ```
  earlycon console=ttyMSM0,115200 console=tty0 loglevel=8 fbcon=rotate:3
  fbcon=font:TER16x32 rootfs=/dev/mmcblk0p62p2 bootpart=/dev/mmcblk0p62p1
  rootfstype=squashfs ro rootwait panic=30
  ```

  `console=tty0 loglevel=8` is why the kernel draws everything on the
  panel; see the display guide and `Fp3Extras.Console`.
* **Storage:** Nerves lives inside Android's `userdata` partition
  (`/dev/mmcblk0p62`), partitioned again: p1 boot, p2 rootfs A (squashfs),
  p3 the data partition (F2FS), mounted at `/root` with `/data` a symlink
  to it. A phone flashed over fastboot keeps the image's partition sizes,
  so a first-boot step grows p3 and its filesystem to fill `userdata`
  (`nerves_data_resize` with the system's `ops.fw` `grow-app` task).
  `/sys/fs/pstore` is mounted, so a kernel panic's trace survives the
  reboot.
* **Hostname:** `nerves-XXXX` from the serial number's last four
  characters (the Wi-Fi MAC's, in fact: `02:00:c2:73:6a:3a` gives
  `nerves-6a3a`). mDNS advertises it. Don't rely on `nerves.local` on a
  LAN with more than one Nerves device.

## Userspace libraries for the hardware

Most of the phone's hardware has a library already, all from
[mlainez](https://github.com/mlainez), started at boot as OTP
applications:

| Library | Hardware |
|---|---|
| `ex_rmtfs`, `ex_remoteproc`, `ex_qbootctl` | Modem storage, DSP start-up, boot slots |
| `ex_qcom_smgr` | The ADSP's sensors: accelerometer, gyroscope, magnetometer, pressure, proximity. No light sensor. |
| `ex_audio` | ALSA routing at boot (mixer settings in the audio guide) |
| `fp3_camera` | Both cameras: stills (`cam-snap`), H.264 streams (`cam-stream`), raw statistics |
| `fp3_modem`, `vintage_net_qmi`, `qmi` (qrtr transport) | Cellular data |
| `ex_nfc` | NFC |
| `ex_location` | GPS |
| `blue_heron` | Bluetooth LE on the WCN3680's `hci0`; takes the controller exclusively, so no `bluetoothd` |
| `nerves_ai` | Nx on the CPU, YOLO, Whisper, small LLMs; also the first-boot resize |

This library covers what those don't: the things a phone UI needs that
are plain sysfs, ALSA and evdev.

[`nerves_livebook_fp3`](https://github.com/mlainez/nerves_livebook_fp3)
is the workshop firmware with a notebook per subsystem (LEDs and the
vibrator, sensors, battery, cameras, NFC, GPS, modem, Bluetooth, audio
routes including the earpiece, Scenic on the screen). Its battery and
screen notebooks cover the same sysfs files as `Fp3Extras.Battery` and
`Fp3Extras.Console`; its LED and vibrator notebook is where
`Fp3Extras.Leds` and `Fp3Extras.Vibrator` come from.

## LEDs and the vibrator

The PMI632 drives both kinds of LED. The notification LED is a multicolor
LED on the PMIC's light pulse generator. Its `multi_intensity` takes red,
green and blue, each from 0 to `max_brightness`, and `brightness` scales
all three, so `Fp3Extras.Leds.set_rgb/2` writes the colour and then full
brightness. The two white flash LEDs are on the PMIC's flash controller.
Writing `brightness` puts them in torch mode, which has no timeout: they
stay on until something writes 0. They are very bright and get hot, so
always pair `torch(true)` with `torch(false)`. The device tree
(`sdm632-fairphone-fp3.dts`) gives the LEDs no labels, so the kernel
names them from colour and function: `rgb:status` (confirmed on a phone,
`max_brightness` 255), `white:flash-0` and `white:flash-1`; the library
finds them by substring.

The notification LED also plays patterns by itself. The LPG driver keeps
a pattern of up to 64 levels in the PMIC's SDAM memory and the PMIC's
PBS sequencer steps through it, writing the LPG channels' PWM value
every so many milliseconds (8 ms units, up to 511 ms a step, one length
for every step), so a blink or a breathing ramp runs with the CPU asleep
and through a suspend to idle. The kernel's `pattern` LED trigger
exposes it as `hw_pattern`, in the trigger's "level ms level 0" form (a
hold, then an instant change; the LPG can't fade). Every lit channel
plays the same table, so only full colours keep their hue in hardware;
the trigger's software `pattern` (a kernel timer stepping `brightness`,
which scales the three channels together) keeps any colour and takes any
timing but stops in suspend. `Fp3Extras.Leds.pattern/3` picks between
them. Two snags on nerves_system_fp3 up to v0.3.0, both handled by the
module: the trigger is a module (`modprobe ledtrig-pattern`), and it
starts with a repeat count of 0 that the LPG driver refuses, so
`hw_pattern` fails with EINVAL until `-1` is written to `repeat`. The
next system builds the trigger in and carries a kernel patch for the
repeat count.

The vibrator is the PMI632's `pm8xxx-vibrator`, a force-feedback input
device rather than a sysfs file. Driving it needs an ioctl, so the system
ships `rumble [-d DEV] MS [STRENGTH]`, which uploads one effect (1 to
10,000 ms, strength 1 to 65,535), plays it and returns when it's over.
`Fp3Extras.Vibrator` wraps it. Every call blocks for the length of the
vibration, so run patterns in a Task if the caller can't wait.

## sysfs paths that matter

| Path | What |
|---|---|
| `/sys/class/backlight/*/` | `brightness` 0..4095, `bl_power` 0/4, `max_brightness` |
| `/sys/class/graphics/fb0/blank` | fbdev emulation of the DRM device: `4` powers the panel down, `0` up (does nothing while a DRM client holds the display; see the display guide) |
| `/sys/class/leds/*/` | The RGB notification LED (`brightness`, `multi_intensity`; probably `rgb:status`) and the two white flash LEDs (`brightness` is torch mode; probably `white:flash-0` and `-1`) |
| `/sys/class/vtconsole/vtcon*/bind` | The framebuffer console (`name` says "frame buffer device") |
| `/proc/sys/kernel/printk` | Console log level |
| `/sys/class/power_supply/qg-battery/` | Fuel gauge: `voltage_now`, `current_now`, `current_avg` (µV, µA, negative discharging), `capacity` (stale, boot-time only), `status`, `temp` (tenths of °C), `health`, `technology`, `charge_full_design` (µAh) |
| `/sys/class/power_supply/pmi632-charger/` | `online`, `status` (writable: `0` suspends USB input, `1` resumes) |
| `/sys/class/power_supply/tcpm-source-psy-*/` | USB-C port: `usb_type` lists the modes and brackets the active one, e.g. `C [PD] PD_DRP` |
| `/sys/power/state`, `/sys/power/mem_sleep` | `mem` → s2idle |
| `/sys/class/rtc/rtc0/wakealarm` | `+N` to wake in N seconds |
| `/sys/class/wakeup/*/` | Wakeup sources and their event counts |
| `/dev/input/event*` | gpio-keys (volume), pm8xxx-pwrkey (power), the touchscreen, the headset jack |
| `/dev/dri/card0` | The msm display controller; `card1` is the GPU render node's card |
| `/dev/video0`, `/dev/video1` | Venus decoder and encoder (numbers can move between boots) |
| `/dev/gpiochip0` | The SoC's GPIOs. 135-138 (the fingerprint SPI) are TrustZone's: don't touch |
| `/sys/fs/pstore/` | The previous panic, if any |

## Video decode

The Venus core decodes H.264, VP8, VP9, HEVC, VC-1, MPEG-2/4 and H.263
up to 4096x4096 through a V4L2 stateful memory-to-memory device
(`qcom-venus`), outputting NV12. `membrane_v4l2_decoder` drives it: a
Rust worker thread owns the device, exports each CAPTURE buffer once as
a DMA-BUF, and leases frames downstream as `%VideoInterop.Frame{}`, so
they reach a video target that accepts DMA-BUF frames with no copy
(Emerge's `Membrane.VideoInterop.Sink` is the one it was written
against). About 150 fps at 1080p, bit-exact with FFmpeg's software
decoder.

Two Venus quirks it works around: after `V4L2_DEC_CMD_STOP` the driver
never flags the last buffer or raises the EOS event (FFmpeg's
`h264_v4l2m2m` hangs on the same thing), and the compose rectangle for
1080p is the full 1088 lines rather than the visible 1080. A third,
fixed in the system since v0.1.4: a session idle for two seconds let
runtime PM collapse the core mid-session and latch a permanent error,
after which encoder and decoder were dead until reboot.

The playback pipeline that used it, for reference, with Emerge as the
video target:

```
MP4 index source -+-> H264.Parser -> V4L2.H264.Decoder -> Pacer -> VideoInterop.Sink -> Emerge
                  +-> AAC.Parser -> AAC.FDK.Decoder -> AudioGate -> PortAudio.Sink -> ALSA
```

The pacer releases frames at their pts (frames hold decoder buffers, so
the queue stays short), the gate holds decoded sound until the first
frame is ready, and the picture is held back by the sound card's output
latency (about 10 ms with PortAudio's low-latency setting, plus its
256-frame buffer). Membrane's precompiled PortAudio arrives as a 100 MB
bundle per platform; a release step trims it to `libportaudio`, `libjack`
and `libdb`.

## Building natives for the phone

* **Rust NIFs** (Rustler) cross-compile with the Nerves toolchain: map
  the `CC` triple to a Rust target (`aarch64-nerves-linux-gnu` to
  `aarch64-unknown-linux-gnu`) and set `CARGO_TARGET_<T>_LINKER` and
  `RUSTFLAGS=-C link-arg=--sysroot=$NERVES_SDK_SYSROOT`.
  `membrane_v4l2_decoder`'s `mix.exs` has the mapping. Rustler writes to
  the source tree's `priv/native`, which every project sharing a path
  dependency shares, so skip the host build or it overwrites the target's.
* **Bundlex** (Membrane's C natives) archives static libraries with a
  plain `ar`. On a Mac that's Apple's `ar`, which silently drops Linux
  objects and leaves NIFs with unresolved symbols. Put a shim first on
  `PATH` for target builds that runs `$CROSSCOMPILE-ar` when
  cross-compiling.
* **Python**: the system has ffmpeg but no Python. A standalone CPython
  (python-build-standalone) can ship in `priv` and be embedded with
  Pythonx; keep `pycache` on the data partition since `priv` is
  read-only.

## Flashing

Fastboot mode is power off, hold Volume Down, plug in USB. A stock,
locked bootloader accepts a `devinfo` partition with the unlocked flag
set, so no Android OEM-unlock step is needed; then a dummy `dtbo`, lk2nd
on `boot`, and the Nerves image on `userdata`. After that, `mix upload`
over the network. Every path erases `userdata`.
