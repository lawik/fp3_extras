# Audio

The sound card is the msm8953's ASoC card: playback and capture through
the ADSP (`q6asm`, MultiMedia1/2 front ends), the WCD9335 codec over
SLIMbus for the microphones, earpiece and headphones, and a loudspeaker
amplifier on Quinary MI2S: the AW8898 on the Fairphone 3, the TAS2557
on the 3+. The headset jack reports plug events as an input device.

## Routing

The kernel's mixer starts with nothing connected. `ex_audio` applies the
route at boot (`config :ex_audio, card: 0, mixer: [...]`):

```elixir
[
  # Loudspeaker: playback (hw:0,0, MultiMedia1) to Quinary MI2S. The same
  # route serves the AW8898 and the TAS2557.
  {"QUIN_MI2S_RX Audio Mixer MultiMedia1", :on},
  {"Speaker Switch", :on},
  # Microphone: capture (hw:0,1, MultiMedia2) from SLIMBUS_0_TX, fed by
  # the codec's SLIM TX7, which takes decimator 7, which takes DMIC1 (the
  # bottom mic). Mono.
  {"MultiMedia2 Mixer SLIMBUS_0_TX", :on},
  {"SLIM TX7 MUX", "DEC7"},
  {"ADC MUX7", "DMIC"},
  {"DMIC MUX7", "DMIC1"},
  {"AIF1_CAP Mixer SLIM TX7", :on}
]
```

The earpiece and headphones go through the codec instead, on
SLIMBUS_0_RX. From the `nerves_livebook_fp3` audio notebook, the
earpiece route (loudspeaker off, same playback device):

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

Unlike the loudspeaker, that path has hardware volume controls (`RX0
Digital Volume`, `EAR PA Volume`). `ExAudio.cset/2` and `cget/1` set and
read any control once `ex_audio` is in the firmware; `Fp3Extras.Volume`
and `Fp3Extras.Mic` use it too, on the card set in `config :ex_audio,
:card`.

## Volume

There's no hardware volume control on the loudspeaker path in the
mixer. ALSA's `softvol` plugin, put in front of the card as the default
device, gives one: alsa-lib scales the samples and exposes a `Master`
control (0..255, linear in dB from -60 to 0). `Fp3Extras.Volume`
sets it through `ExAudio.cset/2` and keeps the level in steps. The
control doesn't exist until the device has been opened once, so setting
it fails after boot until sound has played; call
`Fp3Extras.Volume.reapply/0` once it does. Without `amixer`, as on a
laptop, the level is kept and saved but not applied.

`priv/asound.conf` has the device definitions; it goes in the firmware's
`rootfs_overlay/etc/asound.conf`.

## The microphones

Two digital mics on the codec: DMIC1 at the bottom (the one you speak
into) and DMIC2 at the top (a noise reference). Nothing in the stack
cancels noise or echo for a recording (the ADSP does that only inside
cellular calls), so the top mic is only of use to code that processes
the pair, and off by default. Recording from `hw:0,1`, or the `mic`
device `Fp3Extras.Mic` writes, is mono from the bottom mic.

The codec sends one channel per SLIM TX port that's switched on, and
the capture device has to be opened with exactly that many channels; a
different count records silence. Switching the top mic on means routing
DMIC2 through decimator 8 to TX8 and opening with two channels (channel
0 bottom, channel 1 top).

**On v0.2.4 that path doesn't work**, in two ways:

* Two channels with both ports on records only zeros.
* Opening the capture device with *one* channel while two ports are on
  panics the kernel. The phone reboots; the trace is in
  `/sys/fs/pstore`. The log beforehand fills with
  `wcd9335_slimbus_irq: overflow error on TX port 7`.

A kernel patch that arms every TX port of a capture DAI
(`ASoC-codecs-wcd9335-arm-every-TX-port-of-a-capture-DAI`) is being
tried as a `patches/linux` patch in a `nerves_system_fp3` build; until
it's in a release, `Mic.set_secondary(true)` refuses unless started with
`experimental: true`.

Earlier systems had their own audio crashes: v0.2.2 panicked in the
SLIMbus controller when playing and recording at once (a DMA completion
after the sender had returned), fixed in v0.2.4 along with silent first
recordings and a one-in-seven silent boot. Treat multi-stream audio on
an older system as a reboot risk.

## Playback from Elixir

Membrane's PortAudio sink (`membrane_portaudio_plugin`) plays through
ALSA's default device, so through softvol. With `latency: :low` and a
2048-frame ring buffer, the output latency is about 10 ms plus
PortAudio's 256-frame buffer. A video player, for example, holds the
picture back by that much to keep sound and picture together (the
hardware guide has one such pipeline). Membrane's default input queue
before the sink holds about 0.85 s of sound, which plays on after a
pause unless the queue is made small (`target_queue_size: 8_192` bytes, about 46 ms at 44.1 kHz
stereo).

The precompiled PortAudio bundle is about 100 MB per platform; a release
step can drop everything but `libportaudio.so`, `libjack.so` and
`libdb-5.3.so` (`libasound` comes from the system) and Bundlex's
download cache.
