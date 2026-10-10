# Changelog

## Unreleased

### Added

- `Fp3Extras.Sleep`: the whole sleep sequence. Runs the application's
  hook to blank the display, stops the ADSP sensor streams, takes the
  kernel console off the panel, suspends with the RTC alarm, restarts
  the streams, runs the wake hook, and waits for Wi-Fi, restarting its
  firmware if it doesn't come back. Reports what woke the phone and how
  far the monotonic clock fell behind the wall clock.
- `Fp3Extras.WiFi`: the WCNSS remoteproc restart, a wait on VintageNet's
  connection, wake-on-wireless triggers through wpa_supplicant, and
  `Fp3Extras.WiFi.PowerManager`, a `VintageNet.PowerManager` for `wlan0`.
  The restart itself hasn't been run on a phone yet.

### Changed

- The suspend guide now has the display pipeline's cost and how to
  power it down without Emerge's help, the sensor streams and the BEAM's
  wakeups, the wake sources that don't work, the Wi-Fi failure at
  suspend entry and the wake-on-wireless results, the hang seen with
  the GPU mid-frame, and the measured console stall figures.

## v0.1.0

First release: the hardware modules lifted out of the nerves_phone
project (backlight, screen, console, volume, buttons, power, battery,
orientation, light sensor, mic) with the two experiments (fingerprint
GPIOs, QSEECom), and the hardware, display, suspend and audio guides.
