defmodule Fp3Extras.Orientation do
  @moduledoc """
  Which way up the phone is held, from the accelerometer.

  The orientation is `:portrait`, `:landscape_left` (the top of the phone
  pointing left, turned counter-clockwise) or `:landscape_right`. Upside
  down isn't used, like on most phones.

  How it's picked is the `mode`:

    * `:auto` - follows the accelerometer, read four times a second
      through `ExQcomSmgr.read(:accel)` (`ex_qcom_smgr`, the sensors on
      the ADSP). A new orientation has to hold for half a second, and the
      phone has to be tilted well into it (within 30° of upright or
      sideways), so it doesn't flip back and forth at 45°. Lying flat
      keeps the orientation it had.
    * `:portrait` or `:landscape` - locked. Landscape is the side the
      phone was last turned to, or left.

  Without `ex_qcom_smgr` (a laptop) `:auto` stays portrait and the locked
  modes are how landscape is tried out.

  The mode is saved to `orientation.json` under
  `Fp3Extras.state_dir/0`. Changes go to `:notify` as
  `%{orientation: ..., mode: ..., sensor: boolean}`.

  ## Axes

  Orientation is worked out in the screen's axes: x to its right, y to
  its top, and readings the reaction to gravity (y is +9.8 m/s² held
  upright). The sensor may be mounted turned, and on the Fairphone 3 it
  is: held upright, its x reads +9.8. So the default `:axes` swaps them,
  `[x: {:y, 1}, y: {:x, 1}]`: each screen axis names the sensor axis it
  is and which way it goes.
  """

  use GenServer

  @compile {:no_warn_undefined, ExQcomSmgr}

  @poll_ms 250
  # Readings in a row a new orientation needs (half a second).
  @settle 2
  @gravity 9.81
  @fp3_axes [x: {:y, 1}, y: {:x, 1}]

  @type orientation :: :portrait | :landscape_left | :landscape_right
  @type mode :: :auto | :portrait | :landscape

  @doc """
  Options: `:notify` (a one-argument function), `:mode` (the mode before
  one is saved, `:auto`), `:axes` (see the module doc), `:name`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The orientation, the mode, and whether there's an accelerometer."
  @spec current(GenServer.server()) :: %{
          orientation: orientation(),
          mode: mode(),
          sensor: boolean()
        }
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc "Sets how the orientation is picked, and saves it."
  @spec put_mode(GenServer.server(), mode()) :: :ok
  def put_mode(server \\ __MODULE__, mode) when mode in [:auto, :portrait, :landscape],
    do: GenServer.cast(server, {:put_mode, mode})

  @doc """
  The orientation a reading points to, or nil when it's too flat or too
  close to a diagonal to tell. `reading` is the reaction to gravity in
  the screen's axes: x to the right of the screen, y to its top.
  """
  @spec classify(%{x: number(), y: number()}) :: orientation() | :upside_down | nil
  def classify(%{x: x, y: y}) do
    # Mostly flat: the screen faces up or down, so there's no up.
    if :math.sqrt(x * x + y * y) < 0.45 * @gravity do
      nil
    else
      angle = :math.atan2(x, y) * 180 / :math.pi()

      cond do
        abs(angle) <= 30 -> :portrait
        abs(angle - 90) <= 30 -> :landscape_left
        abs(angle + 90) <= 30 -> :landscape_right
        abs(angle) >= 150 -> :upside_down
        true -> nil
      end
    end
  end

  @doc "A sensor reading (`%{x:, y:, z:}`) in the screen's axes, per `:axes`."
  @spec to_screen_axes(map(), keyword()) :: %{x: number(), y: number()}
  def to_screen_axes(reading, axes \\ @fp3_axes) do
    {x_axis, x_sign} = Keyword.get(axes, :x, {:x, 1})
    {y_axis, y_sign} = Keyword.get(axes, :y, {:y, 1})
    %{x: x_sign * Map.fetch!(reading, x_axis), y: y_sign * Map.fetch!(reading, y_axis)}
  end

  @impl GenServer
  def init(opts) do
    sensor = Code.ensure_loaded?(ExQcomSmgr)

    state = %{
      notify: opts[:notify] || fn _ -> :ok end,
      axes: opts[:axes] || @fp3_axes,
      mode: load_mode(opts[:mode] || :auto),
      sensor: sensor,
      # What the accelerometer says, settled, and the side last seen.
      sensed: :portrait,
      landscape: :landscape_left,
      candidate: nil,
      count: 0,
      orientation: :portrait
    }

    if sensor, do: send(self(), :poll)
    {:ok, publish(%{state | orientation: effective(state)})}
  end

  @impl GenServer
  def handle_call(:current, _from, state),
    do: {:reply, Map.take(state, [:orientation, :mode, :sensor]), state}

  @impl GenServer
  def handle_cast({:put_mode, mode}, state) do
    save_mode(mode)
    {:noreply, update(%{state | mode: mode})}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)

    case ExQcomSmgr.read(:accel) do
      {:ok, reading} ->
        {:noreply, sense(state, classify(to_screen_axes(reading, state.axes)))}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  # A reading counts once it's held for @settle polls in a row.
  defp sense(state, sensed) when sensed in [:portrait, :landscape_left, :landscape_right] do
    count = if sensed == state.candidate, do: state.count + 1, else: 1

    if count >= @settle and sensed != state.sensed do
      landscape = if sensed == :portrait, do: state.landscape, else: sensed
      update(%{state | sensed: sensed, landscape: landscape, candidate: sensed, count: count})
    else
      %{state | candidate: sensed, count: count}
    end
  end

  defp sense(state, _flat_or_upside_down), do: %{state | candidate: nil, count: 0}

  defp effective(%{mode: :auto, sensor: true, sensed: sensed}), do: sensed
  defp effective(%{mode: :auto}), do: :portrait
  defp effective(%{mode: :portrait}), do: :portrait
  defp effective(%{mode: :landscape, landscape: side}), do: side

  # Published on every change, as the mode may show in a UI even when
  # the orientation stays the same.
  defp update(state), do: publish(%{state | orientation: effective(state)})

  defp publish(state) do
    state.notify.(Map.take(state, [:orientation, :mode, :sensor]))
    state
  end

  defp path, do: Path.join(Fp3Extras.state_dir(), "orientation.json")

  defp load_mode(default) do
    with {:ok, json} <- File.read(path()),
         {:ok, %{"mode" => mode}} when mode in ~w(auto portrait landscape) <- JSON.decode(json) do
      String.to_existing_atom(mode)
    else
      _none -> default
    end
  end

  defp save_mode(mode) do
    File.mkdir_p!(Fp3Extras.state_dir())
    File.write(path(), JSON.encode!(%{mode: mode}))
  end
end
