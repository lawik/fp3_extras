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

  A measurement subscribes to small NV12 frames (`Fp3Camera.subscribe/2`)
  at a manual exposure and gain, lets a few frames go by for the settings
  to take, and averages the luma of the next ones. The camera's ISP
  applies a gamma curve, so the mean is taken back to linear (gamma 2.2)
  and scaled by the exposure:

      light = (luma / 255) ^ 2.2 / (exposure_s * gain)

  The first try is at 30 ms and 8x gain, for a dim room; if the picture
  clips, a less sensitive setting is used, down to 250 µs at unity gain
  for daylight. About a second per try; don't call it from a process
  that mustn't block.

  `level/1` maps the result onto 0.0..1.0 on a log scale between `:dark`
  and `:bright`:

      config :fp3_extras, :light_sensor, dark: 0.001, bright: 1000

  Needs `fp3_camera`. Without it `measure/0` returns `{:error, :no_camera}`,
  or `{:ok, value}` with `host_light: value` in the config. While the
  front camera streams, `{:error, :camera_busy}`.
  """

  @behaviour Fp3Extras.LightSensor.Source

  @compile {:no_warn_undefined, Fp3Camera}

  # {gain, exposure in µs}, from dim light to bright.
  @settings [{8.0, 30_000}, {1.0, 4_000}, {1.0, 250}]
  # Small enough to average quickly, large enough for both phones' front
  # cameras (at least a sixteenth of the largest mode).
  @size {320, 240}
  # Frames before the manual settings have surely taken.
  @settle 4
  # Frames averaged after that.
  @average 2
  # A mean luma above this has clipped highlights.
  @clip 235
  @frame_timeout_ms 5_000

  @doc "Measures the light now. Blocks for a second or more."
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
        measure_at(@settings)
    end
  end

  defp measure_at([{gain, exposure} | rest]) do
    with {:ok, luma} <- mean_luma(gain, exposure) do
      if luma >= @clip and rest != [],
        do: measure_at(rest),
        else: {:ok, :math.pow(luma / 255, 2.2) / (exposure / 1.0e6 * gain)}
    end
  end

  defp mean_luma(gain, exposure) do
    {width, height} = @size
    opts = [width: width, height: height, exposure: exposure, gain: gain, awb: false]

    with {:ok, subscription} <- Fp3Camera.subscribe(:front, opts) do
      try do
        with :ok <- skip_frames(@settle),
             {:ok, means} <- frame_means(@average, []) do
          {:ok, Enum.sum(means) / length(means)}
        end
      after
        Fp3Camera.unsubscribe(subscription)
        flush_frames()
      end
    end
  end

  defp skip_frames(0), do: :ok

  defp skip_frames(n) do
    receive do
      {:camera_frame, _frame} -> skip_frames(n - 1)
    after
      @frame_timeout_ms -> {:error, :no_frames}
    end
  end

  defp frame_means(0, means), do: {:ok, means}

  defp frame_means(n, means) do
    receive do
      {:camera_frame, %{width: width, height: height, data: data}} ->
        # NV12: the luma plane comes first, one byte a pixel.
        luma = binary_part(data, 0, width * height)
        frame_means(n - 1, [byte_sum(luma, 0) / (width * height) | means])
    after
      @frame_timeout_ms -> {:error, :no_frames}
    end
  end

  defp byte_sum(<<byte, rest::binary>>, sum), do: byte_sum(rest, sum + byte)
  defp byte_sum(<<>>, sum), do: sum

  defp flush_frames do
    receive do
      {:camera_frame, _frame} -> flush_frames()
    after
      0 -> :ok
    end
  end

  @doc "A measurement on 0.0 (dark) to 1.0 (bright), on a log scale."
  @impl true
  @spec level(number()) :: float()
  def level(light) do
    dark = :math.log10(config()[:dark] || 0.001)
    bright = :math.log10(config()[:bright] || 1000)
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
