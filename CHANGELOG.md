# Changelog

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
