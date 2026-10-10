defmodule Fp3Extras.Vibrator do
  @moduledoc """
  The vibration motor, through nerves_system_fp3's `rumble` tool.

  The Fairphone 3's vibrator hangs off the PMI632 PMIC and the kernel
  exposes it (`pm8xxx-vibrator`) as a force-feedback input device under
  `/dev/input`, not as a sysfs file. Making it vibrate means uploading a
  force-feedback effect with an ioctl and then writing an event to play
  it, and Elixir can't issue ioctls, so the Nerves system ships a small
  tool for it:

      rumble [-d /dev/input/eventN] DURATION_MS [STRENGTH]

  It finds the first input device that supports `FF_RUMBLE` (or uses the
  one given with `-d`), plays one rumble of `DURATION_MS` (1 to 10000)
  at `STRENGTH` (1 to 65535, default 65535), waits until it has played,
  and exits. The driver turns the strength into a motor voltage, keeping
  only the top bits, so strengths below 256 don't vibrate at all and
  the steps in between are coarse.

  Every call here runs the tool and so blocks for the duration of the
  vibration, plus the time to start a process. `pattern/2` plays a
  sequence back to back in the calling process; run it in a `Task` if
  the caller can't wait.

  The executable is `rumble` on the PATH, or what's configured:

      config :fp3_extras, :rumble, "/usr/bin/rumble"

  Where it isn't there (a laptop), calls return `{:error, :enoent}`.
  """

  @max_ms 10_000

  @typedoc """
  Options: `:strength`, 1..65535 (default the tool's, 65535), and
  `:device`, an input device path for `rumble -d`.
  """
  @type opts :: [strength: 1..65_535, device: Path.t()]

  @typedoc "A step of a pattern: vibrate for `on_ms`, then pause `pause_ms`."
  @type step :: {on_ms :: 1..10_000, pause_ms :: non_neg_integer()} | (on_ms :: 1..10_000)

  @doc "Whether the `rumble` tool is there."
  @spec available?() :: boolean()
  def available?, do: find_executable() != nil

  @doc """
  Vibrates for `ms` milliseconds (1 to 10000), returning once it has
  stopped.
  """
  @spec rumble(1..10_000, opts()) :: :ok | {:error, term()}
  def rumble(ms, opts \\ []) when is_integer(ms) and ms in 1..@max_ms do
    case find_executable() do
      nil ->
        {:error, :enoent}

      exe ->
        case System.cmd(exe, args(ms, opts), stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, status} -> {:error, {:rumble, status, String.trim(output)}}
        end
    end
  end

  @doc """
  Plays a pattern: each step vibrates for `on_ms` and then pauses for
  `pause_ms` (a bare integer is a step with no pause). Blocks until the
  whole pattern has played, and stops at the first error.

      Fp3Extras.Vibrator.pattern([{100, 100}, {100, 100}, 400])
  """
  @spec pattern([step()], opts()) :: :ok | {:error, term()}
  def pattern(steps, opts \\ []) when is_list(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      {on_ms, pause_ms} = normalize(step)

      case rumble(on_ms, opts) do
        :ok ->
          if pause_ms > 0, do: Process.sleep(pause_ms)
          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  defp normalize({on_ms, pause_ms}) when is_integer(pause_ms) and pause_ms >= 0,
    do: {on_ms, pause_ms}

  defp normalize(on_ms) when is_integer(on_ms), do: {on_ms, 0}

  defp args(ms, opts) do
    device = if device = opts[:device], do: ["-d", device], else: []

    strength =
      case Keyword.fetch(opts, :strength) do
        {:ok, strength} when strength in 1..65_535 -> [Integer.to_string(strength)]
        {:ok, other} -> raise ArgumentError, "strength must be 1..65535, got: #{inspect(other)}"
        :error -> []
      end

    device ++ [Integer.to_string(ms)] ++ strength
  end

  defp find_executable,
    do: System.find_executable(Application.get_env(:fp3_extras, :rumble, "rumble"))
end
