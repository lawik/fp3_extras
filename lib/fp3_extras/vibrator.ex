defmodule Fp3Extras.Vibrator do
  @moduledoc """
  The vibration motor, through the system's `rumble` tool.

  The PMI632's `pm8xxx-vibrator` is a force-feedback input device, which
  needs an ioctl, so the system ships
  `rumble [-d /dev/input/eventN] DURATION_MS [STRENGTH]`: one rumble of
  1..10000 ms at strength 1..65535 (default 65535), returning when it has
  played. The driver keeps only the top bits of the strength, so values
  below 256 don't move the motor.

  Every call blocks for the vibration; run `pattern/2` in a Task if the
  caller can't wait. The executable is `rumble` on the PATH or
  `config :fp3_extras, :rumble, path`. Without it, `{:error, :enoent}`.
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
