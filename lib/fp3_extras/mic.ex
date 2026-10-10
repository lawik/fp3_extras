defmodule Fp3Extras.Mic do
  @moduledoc """
  The two microphones, and the ALSA device to record from.

  The WCD9335 codec has `DMIC1` at the bottom (speech) and `DMIC2` at the
  top (a noise reference). Nothing in the stack cancels noise or echo for
  recordings, so the top mic only helps code that processes the pair. It
  is off by default.

  Capture is device 1 of ex_audio's card (`hw:0,1`, MultiMedia2 from
  SLIMBUS_0_TX). ex_audio routes the bottom mic to SLIM TX7 at boot, so
  recording is mono. `set_secondary(true)` routes the top mic to TX8. The
  codec sends one channel per TX port switched on, and the capture device
  must be opened with exactly that many channels: any other count gets
  the ADSP's mix (a mono recording of both mics is their sum, a stereo
  recording of one is it twice). Channel 0 is the bottom mic, 1 the top.
  `channels/0` says how many to open; the top mic is off again after a
  reboot.

  So that `mic` always opens right, this writes ALSA device `mic` as a
  plug over device 1 pinned to the current channel count, in
  `asound.mic.conf` under `Fp3Extras.state_dir/0`. The firmware's
  `asound.conf` loads it as a hook that tolerates the file's absence:
  `asound_conf_hook/0`.
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

  Returns `{:error, reason}` without changing anything if the mixer
  refuses, for instance before the sound card is up. The reason is
  `{control, ex_audio_reason}`, e.g.
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
    # ALSA device "mic", written by Fp3Extras.Mic with the channel count the
    # mixer routes into hw:#{ExAudio.card()},1. A hook, so its absence is fine.
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
  def init(_opts) do
    state = %{secondary: false}
    # Off by default. If the card isn't up yet the switches are off anyway.
    _ = apply_mixer(@secondary_off)
    write_conf(1)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:secondary?, _from, state), do: {:reply, state.secondary, state}

  def handle_call({:set_secondary, on?}, _from, %{secondary: on?} = state),
    do: {:reply, :ok, state}

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
    # Written by Fp3Extras.Mic: #{channels} channel(s), one per routed mic port.
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
