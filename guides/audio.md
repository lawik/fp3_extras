# Audio

The msm8953 ASoC card: playback and capture through the ADSP (`q6asm`,
MultiMedia1/2 front ends), the WCD9335 codec over SLIMbus for the mics,
earpiece and headphones, and a loudspeaker amplifier on Quinary MI2S
(AW8898 on the 3, TAS2557 on the 3+). The headset jack is an input
device.

## Routing

The mixer starts with nothing connected. `ex_audio` applies the route at
boot (`config :ex_audio, card: 0, mixer: [...]`):

```elixir
[
  # Loudspeaker: MultiMedia1 (hw:0,0) to Quinary MI2S.
  {"QUIN_MI2S_RX Audio Mixer MultiMedia1", :on},
  {"Speaker Switch", :on},
  # Bottom mic: MultiMedia2 (hw:0,1) from SLIMBUS_0_TX, TX7, decimator 7, DMIC1.
  {"MultiMedia2 Mixer SLIMBUS_0_TX", :on},
  {"SLIM TX7 MUX", "DEC7"},
  {"ADC MUX7", "DMIC"},
  {"DMIC MUX7", "DMIC1"},
  {"AIF1_CAP Mixer SLIM TX7", :on}
]
```

The earpiece route (loudspeaker off, same playback device), with
hardware volume controls:

```elixir
[
  {"QUIN_MI2S_RX Audio Mixer MultiMedia1", :off},
  {"SLIMBUS_0_RX Audio Mixer MultiMedia1", :on},
  {"SLIM RX0 MUX", "AIF_MIX1_PB"},
  {"RX INT0_1 MIX1 INP0", "RX0"},
  {"RX INT0 DEM MUX", "CLSH_DSM_OUT"},
  {"RX0 Digital Volume", 84},
  {"EAR PA Volume", 4},
  {"Earpiece Switch", :on}
]
```

`ExAudio.cset/2` and `cget/1` set and read any control.

## Volume

The loudspeaker path has no hardware volume control, so ALSA's `softvol`
plugin is the default device: alsa-lib scales samples and exposes a
`Master` control (0..255, linear in dB from -60 to 0). The control only
exists once the device has been opened; `Fp3Extras.Volume.reapply/0`
after the first sound. `priv/asound.conf` goes in the firmware's
`rootfs_overlay/etc/asound.conf`.

## The microphones

DMIC1 at the bottom (speech), DMIC2 at the top (noise reference).
Nothing cancels noise or echo for recordings, so the top mic is off by
default and recording from `hw:0,1` or the `mic` device is mono.

The codec sends one channel per SLIM TX port switched on, and the
capture device must be opened with exactly that many channels; another
count gets the ADSP's mix. `Fp3Extras.Mic.set_secondary/1` routes DMIC2
through decimator 8 to TX8, and `channels/0` says how many to open
(channel 0 bottom, 1 top).

## Playback from Elixir

Membrane's PortAudio sink plays through the default device, so through
softvol. With `latency: :low` the output latency is about 10 ms plus a
256-frame buffer; a video player holds the picture back by that much.
Membrane's default queue before the sink holds about 0.85 s, which plays
on after a pause unless made small (`target_queue_size: 8_192`).

The precompiled PortAudio bundle is about 100 MB per platform; a release
step can keep only `libportaudio.so`, `libjack.so` and `libdb-5.3.so`.
