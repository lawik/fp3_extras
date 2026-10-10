defmodule Fp3Extras.Buttons do
  @moduledoc """
  Volume, power and touch activity from evdev, through `input_event`.

  The volume keys are `gpio-keys`, power is `pm8xxx-pwrkey`, the
  touchscreen its own device. Handlers:

    * `:on_volume` - `fn :up | :down -> any end`, on press and each repeat
    * `:on_power_tap` - `fn -> any end`, press and release within
      `:tap_ms` (600)
    * `:on_touch` - `fn -> any end`, on any touchscreen event

  Handlers run in this process; keep them short. evdev hands every event
  to every reader, so a UI toolkit can read the touchscreen too. Devices
  missing at start aren't picked up later. Stops with `:no_input_event`
  where `input_event` isn't loaded.
  """

  use GenServer
  require Logger

  @compile {:no_warn_undefined, InputEvent}

  @keys [:key_volumeup, :key_volumedown, :key_power]
  @default_tap_ms 600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    if Code.ensure_loaded?(InputEvent) do
      send(self(), :open)

      {:ok,
       %{
         on_volume: opts[:on_volume] || fn _ -> :ok end,
         on_power_tap: opts[:on_power_tap] || fn -> :ok end,
         on_touch: opts[:on_touch] || fn -> :ok end,
         tap_ms: opts[:tap_ms] || @default_tap_ms,
         power_down_at: nil,
         devices: %{}
       }}
    else
      {:stop, :no_input_event}
    end
  end

  @impl GenServer
  def handle_info(:open, state) do
    devices =
      for {path, info} <- InputEvent.enumerate(),
          kind = kind(info),
          kind != nil,
          match?({:ok, _}, InputEvent.start_link(path: path)),
          into: %{},
          do: {path, kind}

    if not Enum.any?(devices, fn {_, kind} -> kind == :buttons end) do
      Logger.warning("[buttons] no button devices found")
    end

    {:noreply, %{state | devices: devices}}
  end

  def handle_info({:input_event, path, events}, state) when is_list(events) do
    case state.devices[path] do
      :touchscreen ->
        state.on_touch.()
        {:noreply, state}

      _buttons ->
        {:noreply, Enum.reduce(events, state, &handle_key/2)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Value 1 is a press, 2 a repeat while held, 0 a release.
  defp handle_key({:ev_key, key, value}, state)
       when key in [:key_volumeup, :key_volumedown] and value in [1, 2] do
    state.on_volume.(if key == :key_volumeup, do: :up, else: :down)
    state
  end

  defp handle_key({:ev_key, :key_power, 1}, state), do: %{state | power_down_at: now()}

  defp handle_key({:ev_key, :key_power, 0}, %{power_down_at: down_at} = state)
       when down_at != nil do
    if now() - down_at <= state.tap_ms, do: state.on_power_tap.()
    %{state | power_down_at: nil}
  end

  defp handle_key(_event, state), do: state

  @doc false
  # What an input device is, from what it reports: a touchscreen has
  # multitouch positions, a button device one of the keys.
  def kind(info) do
    cond do
      Keyword.has_key?(info.report_info[:ev_abs] || [], :abs_mt_position_x) -> :touchscreen
      Enum.any?(info.report_info[:ev_key] || [], &(&1 in @keys)) -> :buttons
      true -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
