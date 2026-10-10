defmodule Fp3Extras.Mic do
  @moduledoc """
  The two microphones, and the ALSA device to record from.

  The phone has two digital mics on its WCD9335 codec: `DMIC1` at the
  bottom, the one you speak into, and `DMIC2` at the top, a reference for
  the surrounding noise. Nothing in the sound stack cancels noise or echo
  for a recording (the ADSP only does that inside cellular calls), so the
  top mic is only of use to code that processes the pair itself, and a
  hindrance to anything that just wants a voice. It is off by default.

  Capture is device 1 of ex_audio's card, `hw:0,1` on the phone
  (MultiMedia2 from SLIMBUS_0_TX), fed by the codec's
  SLIM TX ports. `ex_audio` routes the bottom mic through decimator 7 to
  TX7 at boot (the audio guide has the mixer settings), so recording is
  mono.

  `set_secondary(true)` adds the top mic as a second channel, on TX8 next
  to TX7. The capture device then has to be opened with two channels: the
  codec sends one channel per mic port that is switched on, and a
  recording that asks for a different count gets silence. Channel 0 is
  the bottom mic, channel 1 the top one. `channels/0` tells the count to
  open; the top mic is off again after a reboot.

  The mixer is switched through `ex_audio` (`ExAudio.cset/2`), on its
  card. So that a mono recording always works, this writes ALSA device
  `mic` as a plug over device 1 of that card, pinned to the current channel count, in
  `asound.mic.conf` under `Fp3Extras.state_dir/0`. The firmware's
  `asound.conf` loads it as a hook that tolerates the file's absence;
  `asound_conf_hook/0` is the snippet.

  **The two-channel path does not work on nerves_system_fp3 v0.2.4**
  (kernel 6.19.5-msm8953): a two-channel capture with both ports on
  records only zeros, and opening the capture device with one channel
  while two ports are on crashes the kernel (the phone reboots; the trace
  is in `/sys/fs/pstore`; it's in the audio guide). A kernel patch that
  arms every TX port of a capture DAI is being tried. Until it's in,
  `set_secondary(true)` returns `{:error, :unsupported}` unless started
  with `experimental: true`, so nothing stumbles into the crash.

  ## Options

  `:experimental` - allow the top mic. The card is ex_audio's,
  `config :ex_audio, card: 0`.
  """

  use GenServer
  require Logger

  @device "mic"

  # Mixer settings that put the top mic on SLIM TX8 (decimator 8), and that
  # take it off again. The bottom mic on TX7 is routed by ex_audio at boot.
  @secondary_on [
    {"SLIM TX8 MUX", "DEC8"},
    {"ADC MUX8", "DMIC"},
    {"DMIC MUX8", "DMIC2"},
    {"AIF1_CAP Mixer SLIM TX8", :on}
  ]
  @secondary_off [
    {"AIF1_CAP Mixer SLIM TX8", :off},
    {"DMIC MUX8", "ZERO"},
    {"SLIM TX8 MUX", "ZERO"}
  ]

  @doc "The mixer settings that switch the top mic on, for the record."
  def secondary_on, do: @secondary_on

  @doc "The mixer settings that switch the top mic off."
  def secondary_off, do: @secondary_off

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The ALSA device to record from (`arecord -D mic -c 1 -r 16000`)."
  def device, do: @device

  @doc "Whether the top mic is on."
  @spec secondary?() :: boolean()
  def secondary?, do: GenServer.call(__MODULE__, :secondary?)

  @doc "The number of channels to open the capture device with: 1, or 2 with the top mic on."
  @spec channels() :: 1 | 2
  def channels, do: if(secondary?(), do: 2, else: 1)

  @doc """
  Turns the top mic on or off as the second capture channel.

  Returns `{:error, :unsupported}` unless started with `experimental:
  true` (see the module doc), and `{:error, reason}` without changing
  anything if the mixer refuses, for instance before the sound card is
  up. The reason is `{control, ex_audio_reason}`, e.g.
  `{"SLIM TX8 MUX", {1, "amixer: ..."}}`, or `{control, :enoent}` where
  there is no `amixer`.
  """
  @spec set_secondary(boolean()) :: :ok | {:error, term()}
  def set_secondary(on?) when is_boolean(on?),
    do: GenServer.call(__MODULE__, {:set_secondary, on?})

  @doc "The file that defines ALSA device `mic`."
  def conf_path, do: Path.join(Fp3Extras.state_dir(), "asound.mic.conf")

  @doc "The `asound.conf` hook that loads `conf_path/0` when it exists."
  def asound_conf_hook do
    """
    # The microphone: ALSA device "mic" (e.g. `arecord -D mic -c 1 -r 16000`),
    # defined in a file Fp3Extras.Mic writes, as the card's capture
    # device (hw:#{ExAudio.card()},1) has to be opened with exactly as many
    # channels as the mixer routes codec mic ports into it. Loaded as a hook so that the
    # file's absence (before the app has written it) is not an error.
    @hooks [
      {
        func load
        files [ "#{conf_path()}" ]
        errors false
      }
    ]
    """
  end

  @impl GenServer
  def init(opts) do
    state = %{secondary: false, experimental: opts[:experimental] == true}
    # Off by default, also after a restart of this process alone. The card
    # may not be up yet, or there may be no amixer (a laptop); then the
    # switches are at their power-on default (off) anyway.
    _ = apply_mixer(@secondary_off)
    write_conf(1)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:secondary?, _from, state), do: {:reply, state.secondary, state}

  def handle_call({:set_secondary, on?}, _from, %{secondary: on?} = state),
    do: {:reply, :ok, state}

  def handle_call({:set_secondary, true}, _from, %{experimental: false} = state),
    do: {:reply, {:error, :unsupported}, state}

  def handle_call({:set_secondary, on?}, _from, state), do: switch(on?, state)

  defp switch(on?, state) do
    settings = if on?, do: @secondary_on, else: @secondary_off

    case apply_mixer(settings) do
      :ok ->
        write_conf(if on?, do: 2, else: 1)
        Logger.info("mic: top mic #{if on?, do: "on", else: "off"}")
        {:reply, :ok, %{state | secondary: on?}}

      {:error, reason} = error ->
        Logger.warning("mic: could not switch the top mic: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  defp apply_mixer(settings) do
    Enum.reduce_while(settings, :ok, fn {name, value}, :ok ->
      case ExAudio.cset(name, value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  defp write_conf(channels) do
    File.mkdir_p(Fp3Extras.state_dir())

    File.write(conf_path(), """
    # Written by Fp3Extras.Mic.
    # #{channels} channel(s): the sound card's capture device must be opened
    # with as many channels as mic ports are routed into it.
    pcm.#{@device} {
      type plug
      slave {
        pcm "hw:#{ExAudio.card()},1"
        channels #{channels}
      }
    }
    """)
  end
end
