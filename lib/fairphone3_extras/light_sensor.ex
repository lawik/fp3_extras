defmodule Fairphone3Extras.LightSensor.Source do
  @moduledoc """
  What `Fairphone3Extras.Screen` wants from a light sensor, so another
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

defmodule Fairphone3Extras.LightSensor do
  @moduledoc """
  Ambient light, measured with the front camera.

  The Fairphone 3 has no light sensor the kernel exposes (the ADSP's
  sensor manager, `qcom_smgr`, offers accelerometer, gyroscope,
  magnetometer, pressure and proximity), so the front camera stands in.
  It faces the same way as the screen, which is the light that matters.

  A measurement takes two small frames (the sensor's 2x2-binned mode, no
  denoise or sharpening) at one gain and two exposures, and reads the raw
  green mean that `fp3_camera`'s `cam-snap` reports for each. The light
  is how fast that mean rises with exposure, scaled to unity gain:

      light = (green_long - green_short) / (exposure_long - exposure_short) * 32 / gain

  The black level is in both frames and cancels out, so it doesn't matter
  that the sensors' pedestals differ (128 on the Fairphone 3's S5K4H7YX).

  The front module gathers little light: in a fairly dim room at unity
  gain the signal is about one count above black, so the first pair is
  taken at 16x analogue gain (512; 32 is unity). In brighter light that
  clips, and the next pair down is used. Binned, the sensor won't expose
  for longer than its frame (about 1,300 lines on the S5K4H7YX), so the
  long exposure stays under that. About 1.2 s of `cam-snap` all told, so
  don't call it from a process that mustn't block.

  The result is in raw counts per exposure line at unity gain. `level/1`
  maps it onto 0.0..1.0 on a log scale between `:dark` and `:bright`:

      config :fairphone3_extras, :light_sensor, dark: 0.0001, bright: 0.5

  The defaults are rough: a fairly dim room measured 0.00075, which they
  put at 0.24.

  Needs `fp3_camera`. Where it isn't loaded, `measure/0` returns
  `{:error, :no_camera}`, or `{:ok, value}` if `host_light: value` is in
  the config, for trying automatic brightness out on a laptop. While the
  front camera streams (a video call), it returns `{:error, :camera_busy}`.
  """

  @behaviour Fairphone3Extras.LightSensor.Source

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
      path: "/tmp/fairphone3_extras_light.jpg"
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

  defp config, do: Application.get_env(:fairphone3_extras, :light_sensor, [])
end
