# Changelog

## Unreleased

- `Fp3Extras.Leds.pattern/3`, `blink/2`, `breathe/2`: patterns on the
  notification LED, played by the PMIC through a suspend when colour and
  timing allow, by a kernel timer otherwise. `set_rgb/2` and `rgb_off/1`
  end a pattern.
- `Fp3Extras.Screen`: `suspend_after_ms` and `:on_suspend`.
- `Fp3Extras.Sleep` and `Fp3Extras.WiFi`.

## v0.1.0

Backlight, Screen, Console, Volume, Mic, Buttons, Power, Battery,
Orientation, LightSensor, Panel, Leds, Vibrator, the Fingerprint and
QSEECom experiments, and the guides.
