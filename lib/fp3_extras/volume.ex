defmodule Fp3Extras.Volume do
  @moduledoc """
  Playback volume in steps, through an ALSA software volume control.

  The loudspeaker path has no hardware volume control, so ALSA's `softvol`
  plugin sits in front of the card as the default device and this module
  sets its control through `ExAudio.cset/2`. `asound_conf/0` is the
  snippet; it goes in the firmware's `rootfs_overlay/etc/asound.conf`.

  The control only exists once the device has been opened, so setting it
  fails until sound has played; call `reapply/0` then. The raw range is
  0..255, linear in dB from -60 to 0.

  Levels are 0..`steps` (16), kept in an `:atomics` counter and saved to
  `volume` under `Fp3Extras.state_dir/0`. `set/1` never waits on the
  mixer; fast presses apply only the latest level. Without `amixer` the
  level is kept but not applied.

  Options: `:control` (`"Master"`), `:steps` (16), `:default` (10). The
  card is `config :ex_audio, :card`.
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
    # Playback through a software volume control ("#{control}"), set by
    # Fp3Extras.Volume. The control appears the first time the device opens.
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
