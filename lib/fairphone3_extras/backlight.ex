defmodule Fairphone3Extras.Backlight do
  @moduledoc """
  The panel's backlight through `/sys/class/backlight`.

  The Fairphone 3's backlight is a PWM-driven LED driver on the PMI632,
  exposed as one device under `/sys/class/backlight` with
  `max_brightness` 4095. Three attributes matter:

    * `brightness` - 0 to `max_brightness`. 0 is black.
    * `bl_power` - 0 is on, 4 (`FB_BLANK_POWERDOWN`) is off. With the
      backlight off the panel keeps its contents and `brightness` keeps
      its value; turning it back on with a non-zero `brightness` lights
      the panel at that level at once, so set `brightness` to 0 before
      `power(true)` when fading in.
    * `actual_brightness` - what the driver applied.

  Levels here are percentages, mapped to the raw range on a 2.2 power
  curve: the eye is roughly logarithmic, so a linear slider would spend
  most of its travel on the bright end. On that curve 50% looks like
  half, and a fade stepped evenly in percent looks even. The minimum
  non-black raw value is 1; the panel at raw 0 shows nothing.

  Functions take the device directory as an option so tests can point
  them at a directory of files. Without one, the first device under
  `/sys/class/backlight` is used. Where there's none (a laptop), reads
  return `{:error, :no_backlight}` and writes are no-ops returning `:ok`,
  so code built on this runs unchanged on the host.
  """

  @sysfs "/sys/class/backlight"
  @gamma 2.2
  @off 4

  @typedoc "Options: `:device`, the backlight's directory."
  @type opts :: [device: Path.t()]

  @doc "The backlight's directory, or nil where there's none."
  @spec device(opts()) :: Path.t() | nil
  def device(opts \\ []) do
    case Keyword.fetch(opts, :device) do
      {:ok, device} ->
        device

      :error ->
        case Path.wildcard(Path.join(root(), "*")) do
          [device | _] -> device
          [] -> nil
        end
    end
  end

  @doc "The driver's maximum raw level (4095 on the Fairphone 3)."
  @spec max_raw(opts()) :: {:ok, pos_integer()} | {:error, term()}
  def max_raw(opts \\ []) do
    with {:ok, device} <- fetch_device(opts),
         do: Fairphone3Extras.sysfs_int(Path.join(device, "max_brightness"))
  end

  @doc "The raw level now."
  @spec get_raw(opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_raw(opts \\ []) do
    with {:ok, device} <- fetch_device(opts),
         do: Fairphone3Extras.sysfs_int(Path.join(device, "brightness"))
  end

  @doc "The level now, in percent."
  @spec get(opts()) :: {:ok, float()} | {:error, term()}
  def get(opts \\ []) do
    with {:ok, raw} <- get_raw(opts), {:ok, max} <- max_raw(opts), do: {:ok, to_percent(raw, max)}
  end

  @doc "Sets the raw level. Without a backlight, does nothing."
  @spec set_raw(non_neg_integer(), opts()) :: :ok | {:error, term()}
  def set_raw(raw, opts \\ []) when is_integer(raw) and raw >= 0 do
    case device(opts) do
      nil -> :ok
      device -> File.write(Path.join(device, "brightness"), Integer.to_string(raw))
    end
  end

  @doc """
  Sets the level in percent (0.0..100.0) on the 2.2 power curve. 0 is
  black; anything above it is at least raw 1.
  """
  @spec set(number(), opts()) :: :ok | {:error, term()}
  def set(percent, opts \\ []) when is_number(percent) do
    case device(opts) do
      nil ->
        :ok

      _device ->
        with {:ok, max} <- max_raw(opts), do: set_raw(to_raw(percent, max), opts)
    end
  end

  @doc """
  Turns the backlight on or off with `bl_power`. Off keeps `brightness`
  as it was, so turning it on again lights the panel at that level.
  """
  @spec power(boolean(), opts()) :: :ok | {:error, term()}
  def power(on?, opts \\ []) when is_boolean(on?) do
    case device(opts) do
      nil -> :ok
      device -> File.write(Path.join(device, "bl_power"), if(on?, do: "0", else: "#{@off}"))
    end
  end

  @doc "Whether the backlight is powered (`bl_power` is 0)."
  @spec powered?(opts()) :: {:ok, boolean()} | {:error, term()}
  def powered?(opts \\ []) do
    with {:ok, device} <- fetch_device(opts),
         {:ok, value} <- Fairphone3Extras.sysfs_int(Path.join(device, "bl_power")),
         do: {:ok, value == 0}
  end

  @doc "A percentage to the raw level, on the 2.2 power curve."
  @spec to_raw(number(), pos_integer()) :: non_neg_integer()
  def to_raw(percent, _max) when percent <= 0, do: 0

  def to_raw(percent, max) do
    percent = min(percent, 100)
    max(1, round(max * :math.pow(percent / 100, @gamma)))
  end

  @doc "A raw level to the percentage, the inverse of `to_raw/2`."
  @spec to_percent(non_neg_integer(), pos_integer()) :: float()
  def to_percent(0, _max), do: 0.0
  def to_percent(raw, max), do: 100 * :math.pow(min(raw, max) / max, 1 / @gamma)

  defp fetch_device(opts) do
    case device(opts) do
      nil -> {:error, :no_backlight}
      device -> {:ok, device}
    end
  end

  defp root, do: Application.get_env(:fairphone3_extras, :backlight_root, @sysfs)
end
