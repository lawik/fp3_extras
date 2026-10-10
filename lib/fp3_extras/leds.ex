defmodule Fp3Extras.Leds do
  @moduledoc """
  The notification LED and the flashlight through `/sys/class/leds`.

  The Fairphone 3 has two kinds of LED, both driven by the PMI632 PMIC:

    * An RGB notification LED, driven by the PMIC's LPG (light pulse
      generator) and registered as one multicolor LED. Its
      `multi_intensity` takes three numbers, red, green and blue, each
      0 to `max_brightness`, and its `brightness` scales all three at
      once. `set_rgb/2` writes the colour and then `brightness` at the
      maximum, so the colour is what you asked for.
    * Two white flash LEDs next to the rear camera, driven by the PMIC's
      flash controller (`leds-qcom-flash`). Writing `brightness` puts an
      LED in torch mode: it stays on, at that current, until something
      writes 0. There is no timeout in torch mode (the flash timeout only
      applies to a strobe, which the camera stack fires). The LEDs are
      very bright and get hot, so whoever turns them on must turn them
      off; `torch(false)` does that.

  The device tree gives the LEDs no `label`, so the kernel names them
  from their colour and function: on the kernel nerves_system_fp3 builds
  that should be `rgb:status` for the notification LED and
  `white:flash-0` and `white:flash-1` for the flash LEDs. That's from
  reading the device tree, not from a listing on a phone, so the LEDs
  are found as the workshop notebook found them, by a substring of the
  name: "rgb" for the notification LED and "flash" for the flash LEDs.
  Every function that picks an LED also takes an explicit name with the
  `:led` option.

  Functions take the LED class directory as the `:root` option (default
  `/sys/class/leds`) so tests can point them at a directory of files.
  Where there's no such directory (a laptop), reads return
  `{:error, :no_leds}` and writes are no-ops returning `:ok`, so code
  built on this runs unchanged on the host.
  """

  import Kernel, except: [max: 2]

  @sysfs "/sys/class/leds"

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
             intensity = Enum.map_join([r, g, b], " ", &div(&1 * max, 255)),
             :ok <- write(led, "multi_intensity", intensity, opts),
             do: set(led, max, opts)
    end
  end

  @doc "Turns the notification LED off. Without it, does nothing."
  @spec rgb_off(opts()) :: :ok | {:error, term()}
  def rgb_off(opts \\ []) do
    case rgb(opts) do
      nil -> :ok
      led -> off(led, opts)
    end
  end

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
