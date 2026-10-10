# Changelog

## Unreleased

### Added

- `Fp3Extras.Leds.pattern/3`, `blink/2` and `breathe/2`: patterns on
  the notification LED, played by the PMIC (through a suspend) when the
  colour and timing allow and by the kernel's timer otherwise. The
  hardware guide has how the PMIC does it and the two snags on
  nerves_system_fp3 up to v0.3.0 that the module works around.
- The suspend guide notes that the status LED, colour or pattern, keeps
  going through suspend to idle.

### Changed

- `Fp3Extras.Leds.set_rgb/2` and `rgb_off/1` end a running pattern.

## v0.1.0

First release: the hardware modules lifted out of the nerves_phone
project (backlight, screen, console, volume, buttons, power, battery,
orientation, light sensor, mic) with the two experiments (fingerprint
GPIOs, QSEECom), and the hardware, display, suspend and audio guides.

Then, from a pass over mlainez's Fairphone 3 repositories: the Panel
module (fbdev's blank, which powers the display pipeline down once no
DRM client holds the display), LEDs and the vibrator from the workshop
firmware's notebook, a fuller Battery (temperature, health, design
capacity, USB-C mode, a time-left estimate), and Volume and Mic setting
the mixer through ex_audio instead of running amixer themselves.
