defmodule Fp3Extras.LightSensor.Source do
  @moduledoc """
  What `Fp3Extras.Screen` wants from a light sensor, so another
  (a real sensor on a different phone, a fake one in tests) can stand in
  for the camera.
  """

  @doc "Measures the light now. May block for a while."
  @callback measure() :: {:ok, number()} | {:error, term()}

  @doc "A measurement on 0.0 (dark) to 1.0 (bright)."
  @callback level(number()) :: float()

  @doc "A few words for a measurement."
  @callback describe(number()) :: String.t()
end

defmodule Fp3Extras.LightSensor do
  @moduledoc """
  Ambient light from the front camera.

  The Fairphone 3 has no light sensor (the ADSP offers accelerometer,
  gyroscope, magnetometer, pressure and proximity). The front camera
  faces the same way as the screen.

  A measurement takes two binned frames (no denoise or sharpening) at one
  gain and two exposures and reads the raw green mean of each from
  `fp3_camera`'s `cam-snap`:

      light = (green_long - green_short) / (exposure_long - exposure_short) * 32 / gain

  The black level cancels out. The first pair is at 16x gain (a dim room
  gives about one count above black at unity gain); if it clips, the next
  pair down is used. The long exposure stays under the binned frame
  length (about 1,300 lines). About 1.2 s all told; don't call it from a
  process that mustn't block.

  `level/1` maps the result onto 0.0..1.0 on a log scale between `:dark`
  and `:bright`:

      config :fp3_extras, :light_sensor, dark: 0.0001, bright: 0.5

  A fairly dim room measured 0.00075 (0.24 on the defaults).

  Needs `fp3_camera`. Without it `measure/0` returns `{:error, :no_camera}`,
  or `{:ok, value}` with `host_light: value` in the config. While the
  front camera streams, `{:error, :camera_busy}`.
  """

  @behaviour Fp3Extras.LightSensor.Source

  @compile {:no_warn_undefined, Fp3Camera}

  # {gain, short exposure, long exposure}, from dim light to bright.
  @pairs [{512, 50, 1_200}, {32, 50, 1_200}, {32, 4, 50}]
  # 10-bit raw: a mean above this has clipped highlights.
  @clip 900

  @doc "Measures the light now. Blocks for about a second."
  @impl true
  @spec measure() :: {:ok, float()} | {:error, term()}
  def measure do
    cond do
      not Code.ensure_loaded?(Fp3Camera) ->
        case config()[:host_light] do
          nil -> {:error, :no_camera}
          light -> {:ok, light / 1}
        end

      Enum.any?(Fp3Camera.streams(), &(&1.camera == :front)) ->
        {:error, :camera_busy}

      true ->
        measure_pairs(@pairs)
    end
  end

  defp measure_pairs([{gain, short, long} | rest]) do
    with {:ok, low} <- green(gain, short),
         {:ok, high} <- green(gain, long) do
      if high >= @clip and rest != [],
        do: measure_pairs(rest),
        else: {:ok, max(high - low, 0.0) / (long - short) * 32 / gain}
    end
  end

  defp green(gain, exposure) do
    opts = [
      binned: true,
      exposure: exposure,
      gain: gain,
      denoise: 0,
      sharpen: false,
      quality: 30,
      path: "/tmp/fp3_extras_light.jpg"
    ]

    case Fp3Camera.snap_stats(:front, opts) do
      {:ok, %{raw: %{g: g}}} -> {:ok, g}
      {:ok, _no_stats} -> {:error, :no_statistics}
      {:error, _} = error -> error
    end
  end

  @doc "A measurement on 0.0 (dark) to 1.0 (bright), on a log scale."
  @impl true
  @spec level(number()) :: float()
  def level(light) do
    dark = :math.log10(config()[:dark] || 0.0001)
    bright = :math.log10(config()[:bright] || 0.5)
    position = (:math.log10(max(light, 1.0e-6)) - dark) / (bright - dark)
    position |> max(0.0) |> min(1.0)
  end

  @doc "A few words for a measurement."
  @impl true
  def describe(light) do
    case level(light) do
      l when l < 0.2 -> "Dark"
      l when l < 0.45 -> "Dim"
      l when l < 0.7 -> "Indoor light"
      l when l < 0.9 -> "Bright"
      _ -> "Very bright"
    end
  end

  defp config, do: Application.get_env(:fp3_extras, :light_sensor, [])
end
