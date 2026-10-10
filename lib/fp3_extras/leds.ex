defmodule Fp3Extras.Leds do
  @moduledoc """
  The notification LED and the flash LEDs through `/sys/class/leds`.

  Both are on the PMI632. The RGB notification LED (`rgb:status`,
  `max_brightness` 255) is one multicolor LED on the PMIC's LPG:
  `multi_intensity` takes red, green and blue, and `brightness` scales all
  three. `set_rgb/2` writes the colour, then full brightness. The two
  white flash LEDs (`white:flash-0`, `white:flash-1`) are on the flash
  controller; writing `brightness` is torch mode, with no timeout. They
  get hot: pair `torch(true)` with `torch(false)`.

  ## Patterns

  `pattern/3` takes a colour and steps, each a level 0..255 held for some
  milliseconds, and plays them one of two ways:

    * **In the PMIC.** The LPG stores the steps in the PMIC's SDAM and its
      PBS sequencer plays them, so the pattern runs with the CPU asleep
      and through a suspend to idle. Two to 64 steps of one length, each
      under 512 ms (8 ms units). Every lit channel plays the same curve,
      so only full colours keep their hue: red, green, blue, yellow, cyan,
      magenta, white.
    * **On a kernel timer.** The `pattern` trigger steps `brightness`
      itself: any colour, any timing, a wakeup per step, and it stops in
      suspend.

  `:mode` is `:auto` (the PMIC when it can), `:hardware` or `:software`.
  `blink/2` and `breathe/2` build steps. `set_rgb/2` and `rgb_off/1` end
  a pattern. Needs the kernel's `pattern` LED trigger.

  LEDs are found by substring ("rgb", "flash") or named with `:led`.
  `:root` is the LED class directory (for tests). Without it, reads return
  `{:error, :no_leds}` and writes do nothing.
  """

  import Kernel, except: [max: 2]

  require Logger

  @sysfs "/sys/class/leds"
  # The LPG driver's limits for a pattern it plays itself.
  @hw_max_steps 64
  @hw_max_ms 511

  @typedoc """
  Options: `:root`, the LED class directory (default `/sys/class/leds`),
  and, where a function picks an LED itself, `:led`, an explicit name
  (or, for `torch/2`, a list of names).
  """
  @type opts :: [root: Path.t(), led: String.t() | [String.t()]]

  @typedoc "An LED's directory name under the root, such as `rgb:status`."
  @type name :: String.t()

  @doc "The names of every LED under the root, sorted. Empty where there's none."
  @spec list(opts()) :: [name()]
  def list(opts \\ []) do
    case File.ls(root(opts)) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  @doc "The first LED (in sorted order) whose name contains `pattern`, or nil."
  @spec find(String.t(), opts()) :: name() | nil
  def find(pattern, opts \\ []) when is_binary(pattern),
    do: Enum.find(list(opts), &String.contains?(&1, pattern))

  @doc "An LED's `max_brightness`."
  @spec max(name(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def max(led, opts \\ []) when is_binary(led) do
    with {:ok, dir} <- led_dir(led, opts),
         do: Fp3Extras.sysfs_int(Path.join(dir, "max_brightness"))
  end

  @doc "An LED's `brightness` now."
  @spec get(name(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get(led, opts \\ []) when is_binary(led) do
    with {:ok, dir} <- led_dir(led, opts), do: Fp3Extras.sysfs_int(Path.join(dir, "brightness"))
  end

  @doc """
  Writes an LED's raw `brightness`, 0 to `max_brightness`. Without the LED
  class directory, does nothing.
  """
  @spec set(name(), non_neg_integer(), opts()) :: :ok | {:error, term()}
  def set(led, value, opts \\ []) when is_binary(led) and is_integer(value) and value >= 0,
    do: write(led, "brightness", Integer.to_string(value), opts)

  @doc """
  Sets an LED's brightness in percent (0..100) of its `max_brightness`,
  linearly. Anything above 0 is at least raw 1.
  """
  @spec set_percent(name(), number(), opts()) :: :ok | {:error, term()}
  def set_percent(led, percent, opts \\ []) when is_binary(led) and is_number(percent) do
    if File.dir?(root(opts)) do
      with {:ok, max} <- max(led, opts), do: set(led, percent_to_raw(percent, max), opts)
    else
      :ok
    end
  end

  @doc "Turns an LED off (`brightness` 0)."
  @spec off(name(), opts()) :: :ok | {:error, term()}
  def off(led, opts \\ []), do: set(led, 0, opts)

  @doc "The notification LED's name (the first containing \"rgb\"), or nil."
  @spec rgb(opts()) :: name() | nil
  def rgb(opts \\ []), do: Keyword.get_lazy(opts, :led, fn -> find("rgb", opts) end)

  @doc """
  Lights the notification LED in a colour, each channel 0..255. The
  channels are scaled onto `max_brightness` and written to
  `multi_intensity`, then `brightness` is set to the maximum. `{0, 0, 0}`
  leaves the LED lit at zero intensity; use `rgb_off/1` to turn it off.
  Without the LED, does nothing.
  """
  @spec set_rgb({0..255, 0..255, 0..255}, opts()) :: :ok | {:error, term()}
  def set_rgb({r, g, b}, opts \\ []) when r in 0..255 and g in 0..255 and b in 0..255 do
    case rgb(opts) do
      nil ->
        :ok

      led ->
        with {:ok, max} <- max(led, opts),
             :ok <- end_pattern(led, opts),
             :ok <- write(led, "multi_intensity", intensity({r, g, b}, max), opts),
             do: set(led, max, opts)
    end
  end

  @doc "Turns the notification LED off, ending any pattern. Without it, does nothing."
  @spec rgb_off(opts()) :: :ok | {:error, term()}
  def rgb_off(opts \\ []) do
    case rgb(opts) do
      nil -> :ok
      led -> with :ok <- end_pattern(led, opts), do: off(led, opts)
    end
  end

  @typedoc "One step of a pattern: a level, 0..255, and how long to hold it in ms."
  @type step :: {0..255, pos_integer()}

  @typedoc """
  Pattern options, on top of `t:opts/0`: `:mode`, `:auto` (default),
  `:hardware` or `:software`; `:repeat`, `:forever` (default) or `:once`.
  """
  @type pattern_opts :: [
          {:mode, :auto | :hardware | :software}
          | {:repeat, :forever | :once}
          | {:root, Path.t()}
          | {:led, name()}
        ]

  @doc """
  Plays `steps` (at least two) in `color` on the notification LED, over
  and over or once with `repeat: :once`. Returns `{:ok, :hardware}` (the
  PMIC), `{:ok, :software}` (a kernel timer) or `{:ok, :none}` without
  the LED.

      Fp3Extras.Leds.pattern({0, 0, 255}, [{255, 100}, {0, 900}])
  """
  @spec pattern({0..255, 0..255, 0..255}, [step()], pattern_opts()) ::
          {:ok, :hardware | :software | :none} | {:error, term()}
  def pattern({r, g, b} = color, steps, opts \\ [])
      when r in 0..255 and g in 0..255 and b in 0..255 and is_list(steps) do
    with :ok <- check_steps(steps),
         {:ok, mode} <- choose_mode(Keyword.get(opts, :mode, :auto), color, steps) do
      case rgb(opts) do
        nil -> {:ok, :none}
        led -> start_pattern(led, mode, color, steps, opts)
      end
    end
  end

  @doc """
  Blinks the notification LED: `:on_ms` lit, `:off_ms` dark, 500 ms each
  by default. Equal times (and a full colour) let the PMIC do it.
  """
  @spec blink(
          {0..255, 0..255, 0..255},
          [{:on_ms, pos_integer()} | {:off_ms, pos_integer()}] | pattern_opts()
        ) ::
          {:ok, :hardware | :software | :none} | {:error, term()}
  def blink(color, opts \\ []) do
    on = Keyword.get(opts, :on_ms, 500)
    off = Keyword.get(opts, :off_ms, 500)
    pattern(color, [{255, on}, {0, off}], opts)
  end

  @doc """
  Breathes the notification LED: a smooth rise and fall over
  `:period_ms` (2 s by default, up to 10 s) in `:steps` steps (20).
  """
  @spec breathe(
          {0..255, 0..255, 0..255},
          [{:period_ms, pos_integer()} | {:steps, pos_integer()}] | pattern_opts()
        ) ::
          {:ok, :hardware | :software | :none} | {:error, term()}
  def breathe(color, opts \\ []) do
    period = Keyword.get(opts, :period_ms, 2_000)
    count = Keyword.get(opts, :steps, 20)
    pattern(color, breathe_steps(period, count), opts)
  end

  @doc "The steps `breathe/2` plays: a raised cosine from dark to full and back."
  @spec breathe_steps(pos_integer(), pos_integer()) :: [step()]
  def breathe_steps(period_ms, count) when period_ms > 0 and count >= 2 do
    ms = Kernel.max(1, div(period_ms, count))

    for i <- 0..(count - 1) do
      {round(255 * (1 - :math.cos(2 * :math.pi() * i / count)) / 2), ms}
    end
  end

  @doc """
  Whether the PMIC can play `steps` in `color`: two to 64 steps of one
  length under 512 ms, and each channel either off or full.
  """
  @spec hardware_able?({0..255, 0..255, 0..255}, [step()]) :: boolean()
  def hardware_able?({r, g, b}, [{_, ms} | _] = steps) do
    Enum.all?([r, g, b], &(&1 in [0, 255])) and length(steps) in 2..@hw_max_steps and
      ms in 1..@hw_max_ms and Enum.all?(steps, &match?({_, ^ms}, &1))
  end

  def hardware_able?(_color, _steps), do: false

  defp check_steps(steps) do
    cond do
      length(steps) < 2 ->
        {:error, :too_few_steps}

      not Enum.all?(steps, &match?({l, ms} when l in 0..255 and is_integer(ms) and ms > 0, &1)) ->
        {:error, :bad_step}

      true ->
        :ok
    end
  end

  defp choose_mode(:auto, color, steps),
    do: {:ok, if(hardware_able?(color, steps), do: :hardware, else: :software)}

  defp choose_mode(:hardware, color, steps),
    do: if(hardware_able?(color, steps), do: {:ok, :hardware}, else: {:error, :not_for_hardware})

  defp choose_mode(:software, _color, _steps), do: {:ok, :software}
  defp choose_mode(mode, _color, _steps), do: {:error, {:bad_mode, mode}}

  defp start_pattern(led, mode, color, steps, opts) do
    repeat = if Keyword.get(opts, :repeat, :forever) == :once, do: "1", else: "-1"

    with {:ok, max} <- max(led, opts),
         :ok <- ensure_trigger(led, opts),
         :ok <- write(led, "trigger", "pattern", opts),
         :ok <- write(led, "repeat", repeat, opts),
         :ok <- write(led, "multi_intensity", intensity(color, max), opts) do
      play(mode, led, steps, max, opts)
    end
  end

  # PMIC levels are the LUT's bytes; timer levels are brightness, scaled to
  # the maximum. Both take the trigger's "level ms level 0" form (a hold).
  defp play(:hardware, led, steps, max, opts) do
    auto? = Keyword.get(opts, :mode, :auto) == :auto

    case write(led, "hw_pattern", holds(steps, fn l -> l end), opts) do
      :ok ->
        {:ok, :hardware}

      {:error, reason} when auto? ->
        Logger.info(
          "The PMIC refused the LED pattern (#{inspect(reason)}); playing it on a timer"
        )

        play(:software, led, steps, max, opts)

      error ->
        error
    end
  end

  defp play(:software, led, steps, max, opts) do
    with :ok <- write(led, "pattern", holds(steps, &div(&1 * max, 255)), opts),
         do: {:ok, :software}
  end

  defp holds(steps, scale),
    do:
      Enum.map_join(steps, " ", fn {level, ms} -> "#{scale.(level)} #{ms} #{scale.(level)} 0" end)

  defp ensure_trigger(led, opts),
    do: if(trigger_listed?(led, opts), do: :ok, else: {:error, :no_pattern_trigger})

  defp trigger_listed?(led, opts) do
    case File.read(Path.join([root(opts), led, "trigger"])) do
      {:ok, triggers} -> "pattern" in String.split(String.replace(triggers, ["[", "]"], ""))
      _ -> false
    end
  end

  # A pattern keeps playing under a new colour, so take the trigger off.
  defp end_pattern(led, opts) do
    trigger = Path.join([root(opts), led, "trigger"])
    if File.exists?(trigger), do: File.write(trigger, "none"), else: :ok
  end

  defp intensity({r, g, b}, max), do: Enum.map_join([r, g, b], " ", &div(&1 * max, 255))

  @doc "The flash LEDs' names (every LED containing \"flash\"), sorted."
  @spec flash(opts()) :: [name()]
  def flash(opts \\ []) do
    case Keyword.fetch(opts, :led) do
      {:ok, leds} -> List.wrap(leds)
      :error -> Enum.filter(list(opts), &String.contains?(&1, "flash"))
    end
  end

  @doc """
  Turns the flash LEDs on in torch mode, at `max_brightness`, or off.

  On means on until `torch(false)`: torch mode has no timeout. The LEDs
  are bright enough to hurt to look at and get hot, so turn them off when
  done. `:percent` sets a lower level (of `max_brightness`, linearly).
  Without flash LEDs, does nothing.
  """
  @spec torch(boolean(), [{:percent, number()} | {:root, Path.t()} | {:led, name() | [name()]}]) ::
          :ok | {:error, term()}
  def torch(on?, opts \\ []) when is_boolean(on?) do
    percent = if on?, do: Keyword.get(opts, :percent, 100), else: 0

    opts
    |> flash()
    |> Enum.reduce_while(:ok, fn led, :ok ->
      case set_percent(led, percent, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc "A percentage of `max` to a raw level; above 0 is at least 1."
  @spec percent_to_raw(number(), non_neg_integer()) :: non_neg_integer()
  def percent_to_raw(percent, _max) when percent <= 0, do: 0
  def percent_to_raw(percent, max), do: Kernel.max(1, round(max * Kernel.min(percent, 100) / 100))

  defp write(led, file, value, opts) do
    root = root(opts)
    if File.dir?(root), do: File.write(Path.join([root, led, file]), value), else: :ok
  end

  defp led_dir(led, opts) do
    root = root(opts)
    if File.dir?(root), do: {:ok, Path.join(root, led)}, else: {:error, :no_leds}
  end

  defp root(opts), do: Keyword.get(opts, :root, @sysfs)
end
