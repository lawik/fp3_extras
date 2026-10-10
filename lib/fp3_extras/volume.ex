defmodule Fp3Extras.Volume do
  @moduledoc """
  Playback volume in steps, through an ALSA software volume control.

  The Fairphone 3's loudspeaker path (QUIN_MI2S_RX to the AW8898 or, on
  the 3+, the TAS2557 amplifier) has no hardware volume control in the
  kernel's mixer. So volume is ALSA's `softvol` plugin, put in front of
  the sound card in `asound.conf` as the default device: alsa-lib scales
  the samples, and this module sets the control through `ex_audio`
  (`ExAudio.cset/2`), on ex_audio's card. ex_audio is also what routes
  the card's speaker path at boot, from its `:mixer` config. The snippet
  is `asound_conf/0`; nerves_system_fp3 doesn't ship it, so it goes in
  the firmware's `rootfs_overlay/etc/asound.conf`.

  Two things about softvol controls:

    * The control doesn't exist until the device has been opened once
      (alsa-lib creates it on first use). Setting it fails before that,
      so the level is applied again with `reapply/0` once sound has
      started; the player's job.
    * The raw range is 0..255 and linear in dB between `min_dB` and
      `max_dB` (-60 dB to 0 dB in the snippet): each step is the same
      change in loudness, and 0 is silent enough.

  Levels go from 0 to `steps` (16 by default). The current level lives in
  an `:atomics` counter, so reading it is cheap, and is saved to `volume`
  under `Fp3Extras.state_dir/0`. Setting the level never waits on the
  mixer: this process applies it, and when presses come fast only the
  latest level is applied. Where there is no `amixer`, as on a laptop,
  the level is kept and saved but not applied.

  ## Options

  `start_link/1` takes:

    * `:control` - the mixer control's name (`"Master"`)
    * `:steps` - the number of steps above silence (`16`)
    * `:default` - the level before one is saved (`10`)

  The card is ex_audio's, `config :ex_audio, card: 0`.
  """

  use GenServer

  @default_opts [control: "Master", steps: 16, default: 10]

  @doc """
  The `asound.conf` that puts the software volume control in front of the
  card. Takes `:control` and `:card`, which defaults to `ExAudio.card/0`.
  """
  @spec asound_conf(keyword()) :: String.t()
  def asound_conf(opts \\ []) do
    control = opts[:control] || @default_opts[:control]
    card = opts[:card] || ExAudio.card()

    """
    # Playback goes through a software volume control ("#{control}") so the
    # volume is applied in alsa-lib. Fp3Extras.Volume sets it through
    # ex_audio. The control appears the first time the device is opened.
    pcm.!default {
      type plug
      slave.pcm "softvol"
    }

    pcm.softvol {
      type softvol
      slave.pcm "hw:#{card},0"
      control {
        name "#{control}"
        card #{card}
      }
      min_dB -60.0
      max_dB 0.0
    }

    ctl.!default {
      type hw
      card #{card}
    }
    """
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The number of steps above silence."
  @spec steps() :: pos_integer()
  def steps, do: :persistent_term.get({__MODULE__, :steps}, @default_opts[:steps])

  @doc "The current level, 0..steps."
  @spec level() :: non_neg_integer()
  def level, do: :atomics.get(ref(), 1)

  @doc "Sets the level (clamped), saves it and applies it. Returns the new level."
  @spec set(integer()) :: non_neg_integer()
  def set(level) do
    level = level |> max(0) |> min(steps())
    :atomics.put(ref(), 1, level)
    GenServer.cast(__MODULE__, :apply)
    level
  end

  @doc "One step up."
  def up, do: set(level() + 1)

  @doc "One step down."
  def down, do: set(level() - 1)

  @doc "Applies the level again (once the sound device has been opened)."
  @spec reapply() :: :ok
  def reapply, do: GenServer.cast(__MODULE__, :reapply)

  @impl GenServer
  def init(opts) do
    opts = Keyword.merge(@default_opts, opts)
    :persistent_term.put({__MODULE__, :steps}, opts[:steps])
    :persistent_term.put({__MODULE__, :default}, opts[:default])
    # The counter, made here so that it exists before start_link/1 returns:
    # made lazily, a caller and this process could each make one.
    _ = ref()
    send(self(), :apply)
    {:ok, %{applied: nil, control: opts[:control]}}
  end

  @impl GenServer
  def handle_cast(:apply, state), do: handle_info(:apply, state)
  def handle_cast(:reapply, state), do: handle_info(:apply, %{state | applied: nil})

  @impl GenServer
  def handle_info(:apply, state) do
    level = level()

    if level == state.applied do
      {:noreply, state}
    else
      save(level)

      case apply_level(level, state) do
        :ok -> {:noreply, %{state | applied: level}}
        # The control isn't there until sound has played (reapply/0), or
        # there is no amixer at all ({:error, :enoent}, on a laptop).
        {:error, _reason} -> {:noreply, state}
      end
    end
  end

  defp apply_level(level, state) do
    raw = round(255 * level / steps())
    ExAudio.cset(state.control, "#{raw},#{raw}")
  end

  defp ref do
    case :persistent_term.get({__MODULE__, :ref}, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :atomics.put(ref, 1, saved_level())
        :persistent_term.put({__MODULE__, :ref}, ref)
        ref

      ref ->
        ref
    end
  end

  defp save(level) do
    File.mkdir_p(Fp3Extras.state_dir())
    File.write(path(), Integer.to_string(level))
  end

  defp saved_level do
    default = :persistent_term.get({__MODULE__, :default}, @default_opts[:default])

    with {:ok, text} <- File.read(path()),
         {level, _} <- Integer.parse(String.trim(text)) do
      level |> max(0) |> min(steps())
    else
      _ -> default
    end
  end

  defp path, do: Path.join(Fp3Extras.state_dir(), "volume")
end
