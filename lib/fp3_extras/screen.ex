defmodule Fp3Extras.Screen do
  @moduledoc """
  Brightness, dimming and turning off when nobody's touching the screen,
  with fades.

  Modes `:on`, `:dim`, `:off`. Without touches it dims after
  `dim_after_ms` and goes black after `off_after_ms` (from the last touch;
  nil is never). `touch/0` wakes it, `toggle/0` flips it. Feed both from
  `Fp3Extras.Buttons`:

      {Fp3Extras.Buttons,
       on_touch: &Fp3Extras.Screen.touch/0,
       on_power_tap: &Fp3Extras.Screen.toggle/0}

  Levels are percentages faded through `Fp3Extras.Backlight`'s 2.2 curve:
  about a second to dim, 800 ms to black, 250 ms to wake. Once black the
  backlight is powered off; on waking it's set to 0 before power on, so
  the panel doesn't flash at the old level.

  With `auto: true` the level follows `:light_sensor` (a
  `Fp3Extras.LightSensor.Source`, the front camera by default), measured
  when turned on, on waking and every minute while on, in a task.

  `keep_awake/1` keeps the screen on while the calling process wants it,
  or until it exits.

  ## Suspending

  With `suspend_after_ms` set, once the screen has been black that long
  `:on_suspend` is called in a process of its own; put
  `Fp3Extras.Sleep.sleep/1` there. The screen keeps working meanwhile: a
  power-button wake arrives as a tap and brightens it. If the function
  returns with the screen still black the count starts over, so a charger
  or alarm wake goes back to sleep. The count runs from the return, as the
  monotonic clock stops during a suspend.

  ## Settings

  `:brightness` (5..100), `:auto`, `:dim_after_ms`, `:off_after_ms`,
  `:suspend_after_ms` (nil by default). Saved to `display.json` under
  `Fp3Extras.state_dir/0`; `start_link/1`'s `:defaults` seed them.
  Dimming at or after turning off is forced to never; so is suspending
  when the screen never turns off.

  ## Notifying

  `:notify` is called with each change:

    * `{:screen, on?}` - the panel went black or came back. Swallow the
      touch that wakes it, or it presses what was under the finger.
    * `{:display, map}` - the settings plus `level`, `light`,
      `light_error` and `measuring`. The same map is `display/0`.

  Without a backlight the levels are tracked but nothing is written.
  """

  use GenServer
  require Logger

  alias Fp3Extras.Backlight

  @dim_choices [15_000, 30_000, 60_000, 120_000, 300_000, nil]
  @off_choices [30_000, 60_000, 120_000, 300_000, 600_000, nil]
  @suspend_choices [60_000, 300_000, 900_000, 1_800_000, 3_600_000, nil]

  @defaults %{
    brightness: 60,
    auto: false,
    dim_after_ms: 30_000,
    off_after_ms: 60_000,
    suspend_after_ms: nil
  }

  # Brightness never goes below this (the panel at 0 is black).
  @min_brightness 5
  # The dim level, as a share of the on level.
  @dim_share 0.35

  @check_ms 250
  @tick_ms 20
  @sample_ms 60_000
  @save_ms 1_000

  @fade_ms %{dim: 1_000, off: 800, wake: 250, change: 300, auto: 1_500}

  @doc "Choices for dimming and for turning off, in ms (nil is never)."
  def dim_choices, do: @dim_choices
  def off_choices, do: @off_choices

  @doc "Choices for suspending after the screen went black, in ms (nil is never)."
  def suspend_choices, do: @suspend_choices

  @doc "The lowest brightness setting."
  def min_brightness, do: @min_brightness

  @doc """
  Options: `:notify` (a one-argument function, see the module doc),
  `:defaults` (a map or keyword of settings), `:light_sensor` (a
  `Fp3Extras.LightSensor.Source` module), `:on_suspend` (a function of
  no arguments, called when `suspend_after_ms` runs out; see the module
  doc), `:backlight` (the backlight directory, for tests), `:name`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Something touched the screen: stay on, or wake up."
  def touch(server \\ __MODULE__), do: GenServer.cast(server, :touch)

  @doc "The power button: turn the screen off, or on."
  def toggle(server \\ __MODULE__), do: GenServer.cast(server, :toggle)

  @doc """
  Changes settings: `:brightness` (#{@min_brightness}..100), `:auto`,
  `:dim_after_ms`, `:off_after_ms`, `:suspend_after_ms`.
  """
  def put_settings(server \\ __MODULE__, changes),
    do: GenServer.cast(server, {:put_settings, Map.new(changes)})

  @doc "The settings and light reading, as given to `:notify`."
  def display(server \\ __MODULE__), do: GenServer.call(server, :display)

  @doc "The mode now: `:on`, `:dim` or `:off`."
  def mode(server \\ __MODULE__), do: GenServer.call(server, :mode)

  @doc """
  Keeps the screen on while the calling process wants it: until
  `keep_awake(false)`, or the process exits.
  """
  def keep_awake(server \\ __MODULE__, awake?) when is_boolean(awake?),
    do: GenServer.cast(server, {:keep_awake, self(), awake?})

  @doc "Measures the light now (for automatic brightness)."
  def measure(server \\ __MODULE__), do: GenServer.cast(server, :measure)

  # ---------- Server ----------

  @impl GenServer
  def init(opts) do
    send(self(), :check)
    backlight = Backlight.device(device_opt(opts))

    state = %{
      settings: load(opts[:defaults] || %{}),
      notify: opts[:notify] || fn _ -> :ok end,
      light_sensor: opts[:light_sensor] || Fp3Extras.LightSensor,
      on_suspend: opts[:on_suspend],
      mode: :on,
      last_touch: now(),
      # When the screen went black, and the suspend under way, if any.
      off_since: nil,
      suspending: nil,
      backlight: backlight,
      max_raw: max_raw(backlight),
      written: nil,
      # The level shown now, and the fade under way, if any.
      level: 100.0,
      fade: nil,
      light: nil,
      light_error: nil,
      auto_level: nil,
      measuring: false,
      measured_at: nil,
      save_timer: nil,
      # Processes keeping the screen on, by monitor.
      awake: %{}
    }

    state = state |> maybe_measure() |> fade_to(on_level(state), :change)
    {:ok, publish(state)}
  end

  defp device_opt(opts) do
    case opts[:backlight] do
      nil -> []
      dir -> [device: dir]
    end
  end

  @impl GenServer
  def handle_call(:display, _from, state), do: {:reply, report(state), state}
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}

  @impl GenServer
  def handle_cast(:touch, state) do
    state = %{state | last_touch: now()}
    {:noreply, if(state.mode == :on, do: state, else: wake(state))}
  end

  def handle_cast(:toggle, state) do
    state = %{state | last_touch: now()}

    {:noreply, if(state.mode == :off, do: wake(state), else: turn_off(state))}
  end

  def handle_cast({:put_settings, changes}, state) do
    settings = state.settings |> Map.merge(Map.take(changes, Map.keys(@defaults))) |> validate()
    # Dragging a slider changes the brightness many times a second, so
    # save once it settles.
    if state.save_timer, do: Process.cancel_timer(state.save_timer)
    state = %{state | save_timer: Process.send_after(self(), :save, @save_ms)}
    turned_auto_on? = settings.auto and not state.settings.auto
    state = %{state | settings: settings, last_touch: now()}
    state = if turned_auto_on?, do: measure_now(state), else: state

    state =
      case state.mode do
        :on -> fade_to(state, on_level(state), :change)
        _ -> wake(state)
      end

    {:noreply, publish(state)}
  end

  def handle_cast({:keep_awake, pid, true}, state) do
    if pid in Map.values(state.awake) do
      {:noreply, state}
    else
      state = %{state | awake: Map.put(state.awake, Process.monitor(pid), pid)}
      {:noreply, if(state.mode == :on, do: state, else: wake(state))}
    end
  end

  def handle_cast({:keep_awake, pid, false}, state) do
    awake =
      for {ref, ^pid} <- state.awake, reduce: state.awake do
        acc ->
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)
      end

    {:noreply, %{state | awake: awake, last_touch: now()}}
  end

  def handle_cast(:measure, state), do: {:noreply, state |> measure_now() |> publish()}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{awake: awake} = state)
      when is_map_key(awake, ref),
      do: {:noreply, %{state | awake: Map.delete(awake, ref), last_touch: now()}}

  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_ms)
    # Something wants the screen on: count it as touched.
    state = if state.awake == %{}, do: state, else: %{state | last_touch: now()}
    idle = now() - state.last_touch
    %{dim_after_ms: dim_after, off_after_ms: off_after} = state.settings

    state =
      cond do
        state.mode != :off and off_after != nil and idle >= off_after ->
          turn_off(state)

        state.mode == :off and suspend_due?(state) ->
          suspend(state)

        state.mode == :on and dim_after != nil and idle >= dim_after ->
          %{state | mode: :dim} |> fade_to(dim_level(state), :dim)

        state.mode == :on ->
          maybe_measure(state)

        true ->
          state
      end

    {:noreply, state}
  end

  def handle_info(:save, state) do
    save(state.settings)
    {:noreply, %{state | save_timer: nil}}
  end

  def handle_info(:tick, %{fade: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{fade: fade} = state) do
    t = min((now() - fade.start) / fade.duration, 1.0)
    # Ease in and out.
    eased = t * t * (3 - 2 * t)
    state = write(%{state | level: fade.from + (fade.to - fade.from) * eased})

    if t >= 1.0 do
      state = %{state | fade: nil}
      {:noreply, if(state.mode == :off, do: power(state, false), else: state)}
    else
      Process.send_after(self(), :tick, @tick_ms)
      {:noreply, state}
    end
  end

  def handle_info({:measured, result}, state) do
    state = %{state | measuring: false, measured_at: now()}

    state =
      case result do
        {:ok, light} ->
          level = @min_brightness + state.light_sensor.level(light) * (100 - @min_brightness)
          state = %{state | light: light, light_error: nil, auto_level: level}
          if state.mode == :on, do: fade_to(state, on_level(state), :auto), else: state

        {:error, reason} ->
          Logger.info("[screen] light measurement failed: #{inspect(reason)}")
          %{state | light_error: reason}
      end

    {:noreply, publish(state)}
  end

  # The suspend function returned (the phone woke). Still black: count
  # again from now, as the monotonic clock didn't move while asleep.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{suspending: ref} = state) do
    if reason != :normal,
      do: Logger.warning("[screen] the suspend function crashed: #{inspect(reason)}")

    # Woken into the UI meanwhile (the power button's tap): no count.
    off_since = if state.mode == :off, do: now(), else: nil
    {:noreply, %{state | suspending: nil, off_since: off_since}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------- Off, and suspending ----------

  defp turn_off(state), do: %{state | mode: :off, off_since: now()} |> fade_to(0, :off)

  defp suspend_due?(%{settings: %{suspend_after_ms: nil}}), do: false
  defp suspend_due?(%{on_suspend: nil}), do: false
  defp suspend_due?(%{suspending: suspending}) when suspending != nil, do: false
  defp suspend_due?(%{off_since: nil}), do: false
  defp suspend_due?(state), do: now() - state.off_since >= state.settings.suspend_after_ms

  # In its own process, unlinked: a crash there is logged, not fatal.
  defp suspend(state) do
    {_pid, ref} = spawn_monitor(state.on_suspend)
    %{state | suspending: ref}
  end

  # ---------- Levels ----------

  defp on_level(%{settings: %{auto: true}, auto_level: level}) when level != nil, do: level
  defp on_level(state), do: state.settings.brightness / 1

  defp dim_level(state) do
    on = on_level(state)
    min(on, max(on * @dim_share, @min_brightness / 2))
  end

  defp wake(state) do
    state = if state.mode == :off, do: power(state, true), else: state
    %{state | mode: :on, off_since: nil} |> fade_to(on_level(state), :wake) |> maybe_measure()
  end

  defp fade_to(state, level, kind) do
    if state.fade == nil, do: send(self(), :tick)

    %{
      state
      | fade: %{from: state.level, to: level / 1, start: now(), duration: @fade_ms[kind]}
    }
  end

  # ---------- Light ----------

  # On waking, and every minute while on, if automatic.
  defp maybe_measure(%{settings: %{auto: true}, measuring: false} = state) do
    if state.measured_at == nil or now() - state.measured_at >= @sample_ms,
      do: measure_now(state),
      else: state
  end

  defp maybe_measure(state), do: state

  defp measure_now(%{measuring: true} = state), do: state

  defp measure_now(state) do
    screen = self()
    sensor = state.light_sensor
    Task.start(fn -> send(screen, {:measured, sensor.measure()}) end)
    %{state | measuring: true}
  end

  # ---------- The panel ----------

  defp write(%{backlight: nil} = state), do: state

  defp write(state) do
    raw = Backlight.to_raw(state.level, state.max_raw)
    if raw != state.written, do: Backlight.set_raw(raw, device: state.backlight)
    %{state | written: raw}
  end

  defp power(state, on) do
    if state.backlight do
      # Up from black, not from the level the panel was at when it went off.
      if on, do: Backlight.set_raw(0, device: state.backlight)
      Backlight.power(on, device: state.backlight)
    end

    state.notify.({:screen, on})
    %{state | written: if(on, do: 0, else: state.written)}
  end

  defp max_raw(nil), do: 100

  defp max_raw(backlight) do
    case Backlight.max_raw(device: backlight) do
      {:ok, max} -> max
      _ -> 255
    end
  end

  # ---------- Settings ----------

  defp publish(state) do
    state.notify.({:display, report(state)})
    state
  end

  defp report(state) do
    Map.merge(state.settings, %{
      level: round(on_level(state)),
      light: state.light && state.light_sensor.describe(state.light),
      light_error: state.light_error,
      measuring: state.measuring
    })
  end

  defp validate(settings) do
    brightness = settings.brightness |> round() |> max(@min_brightness) |> min(100)

    dim =
      if settings.dim_after_ms in @dim_choices,
        do: settings.dim_after_ms,
        else: @defaults.dim_after_ms

    off =
      if settings.off_after_ms in @off_choices,
        do: settings.off_after_ms,
        else: @defaults.off_after_ms

    dim = if dim != nil and off != nil and dim >= off, do: nil, else: dim

    suspend =
      if Map.get(settings, :suspend_after_ms) in @suspend_choices,
        do: settings.suspend_after_ms,
        else: @defaults.suspend_after_ms

    # Suspending counts from the screen going black; never black, never.
    suspend = if off == nil, do: nil, else: suspend

    %{
      settings
      | brightness: brightness,
        auto: settings.auto == true,
        dim_after_ms: dim,
        off_after_ms: off,
        suspend_after_ms: suspend
    }
  end

  defp path, do: Path.join(Fp3Extras.state_dir(), "display.json")

  defp load(defaults) do
    defaults = Map.merge(@defaults, Map.new(defaults))

    saved =
      with {:ok, json} <- File.read(path()),
           {:ok, map} when is_map(map) <- JSON.decode(json) do
        for {key, value} <- map,
            atom = Enum.find(Map.keys(@defaults), &(Atom.to_string(&1) == key)),
            into: %{},
            do: {atom, value}
      else
        _ -> %{}
      end

    defaults |> Map.merge(saved) |> validate()
  end

  defp save(settings) do
    File.mkdir_p(Fp3Extras.state_dir())
    File.write(path(), JSON.encode!(settings))
  end

  defp now, do: System.monotonic_time(:millisecond)
end
