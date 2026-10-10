defmodule Fp3Extras.ScreenTest do
  use ExUnit.Case

  import Fp3Extras.TestSupport
  alias Fp3Extras.Screen

  defmodule FakeLight do
    @behaviour Fp3Extras.LightSensor.Source
    def measure, do: {:ok, 0.5}
    def level(_), do: 1.0
    def describe(_), do: "Very bright"
  end

  setup do
    fresh_state_dir()
    me = self()

    %{
      device: fake_backlight(),
      notify: &send(me, {:screen_event, &1})
    }
  end

  # The server may be mid-write (truncated, not yet written): nil then.
  defp raw(device) do
    case device |> Path.join("brightness") |> File.read!() |> Integer.parse() do
      {raw, _} -> raw
      :error -> nil
    end
  end

  defp bl_power(device), do: device |> Path.join("bl_power") |> File.read!()

  test "fades up to the brightness on start, and reports its settings", ctx do
    start_supervised!(
      {Screen, backlight: ctx.device, notify: ctx.notify, defaults: [brightness: 50]}
    )

    assert_receive {:screen_event, {:display, %{brightness: 50, level: 50, auto: false}}}
    wait_for(fn -> raw(ctx.device) == 891 end)
    assert Screen.mode() == :on
  end

  test "dims, goes black with the backlight off, and a touch wakes it", ctx do
    start_supervised!(
      {Screen,
       backlight: ctx.device,
       notify: ctx.notify,
       defaults: [brightness: 50, dim_after_ms: 15_000, off_after_ms: 30_000]}
    )

    # The timeouts count from the last touch; nothing shorter than 15 s is
    # offered, so the state machine is driven by hand through toggle.
    wait_for(fn -> raw(ctx.device) == 891 end)
    Screen.toggle()
    wait_for(fn -> bl_power(ctx.device) == "4" end, 3_000)
    assert raw(ctx.device) == 0
    assert_receive {:screen_event, {:screen, false}}
    assert Screen.mode() == :off

    Screen.touch()
    assert_receive {:screen_event, {:screen, true}}
    wait_for(fn -> bl_power(ctx.device) == "0" and raw(ctx.device) == 891 end)
    assert Screen.mode() == :on
  end

  test "validates settings, turns dimming off when it'd never happen, and saves them", ctx do
    start_supervised!({Screen, backlight: ctx.device, notify: ctx.notify})
    Screen.put_settings(brightness: 200, dim_after_ms: 60_000, off_after_ms: 30_000)

    assert_receive {:screen_event,
                    {:display, %{brightness: 100, dim_after_ms: nil, off_after_ms: 30_000}}}

    path = Path.join(Fp3Extras.state_dir(), "display.json")
    wait_for(fn -> File.exists?(path) end)
    assert %{"brightness" => 100, "dim_after_ms" => nil} = JSON.decode!(File.read!(path))

    # And they're loaded next time.
    stop_supervised!(Screen)
    start_supervised!({Screen, backlight: ctx.device, notify: ctx.notify})
    assert Screen.display().brightness == 100
  end

  test "automatic brightness follows the light sensor", ctx do
    start_supervised!(
      {Screen,
       backlight: ctx.device,
       notify: ctx.notify,
       light_sensor: FakeLight,
       defaults: [brightness: 20]}
    )

    Screen.put_settings(auto: true)

    assert_receive {:screen_event, {:display, %{auto: true, light: "Very bright", level: 100}}},
                   2_000

    wait_for(fn -> raw(ctx.device) == 4095 end, 3_000)
  end

  test "keep_awake holds the screen on while the process lives", ctx do
    start_supervised!({Screen, backlight: ctx.device, notify: ctx.notify})
    Screen.toggle()
    wait_for(fn -> Screen.mode() == :off end)

    holder =
      spawn(fn ->
        Screen.keep_awake(true)
        Process.sleep(:infinity)
      end)

    wait_for(fn -> Screen.mode() == :on end)
    Process.exit(holder, :kill)
    # Still on; the timeout counts from now.
    assert Screen.mode() == :on
  end

  test "suspends after the screen has been black for a while, and again after a wake", ctx do
    me = self()

    # Stands in for a sleep: the phone is "asleep" until the test wakes it.
    on_suspend = fn ->
      send(me, {:suspending, self()})

      receive do
        :wake -> :ok
      end
    end

    start_supervised!(
      {Screen,
       backlight: ctx.device,
       notify: ctx.notify,
       on_suspend: on_suspend,
       defaults: [off_after_ms: 30_000, suspend_after_ms: 60_000]}
    )

    assert Screen.display().suspend_after_ms == 60_000
    Screen.toggle()
    wait_for(fn -> Screen.mode() == :off end)
    refute_receive {:suspending, _}, 300

    # The clock is moved rather than waited for: the screen went black a
    # minute ago.
    :sys.replace_state(Screen, &%{&1 | off_since: &1.off_since - 61_000})
    assert_receive {:suspending, sleeper}, 1_000
    # Not again while the suspend is under way.
    :sys.replace_state(Screen, &%{&1 | off_since: &1.off_since - 61_000})
    refute_receive {:suspending, _}, 400

    # The wake returns the function; the screen is still black, so the
    # count starts over and it suspends again a minute later.
    send(sleeper, :wake)
    wait_for(fn -> :sys.get_state(Screen).suspending == nil end)
    refute_receive {:suspending, _}, 300
    :sys.replace_state(Screen, &%{&1 | off_since: &1.off_since - 61_000})
    assert_receive {:suspending, sleeper}, 1_000
    send(sleeper, :wake)

    # Waking the screen stops the count.
    Screen.touch()
    wait_for(fn -> Screen.mode() == :on end)
    assert :sys.get_state(Screen).off_since == nil
  end

  test "suspending is never when the screen never turns off", ctx do
    start_supervised!({Screen, backlight: ctx.device, notify: ctx.notify})
    Screen.put_settings(off_after_ms: nil, suspend_after_ms: 300_000)
    assert_receive {:screen_event, {:display, %{off_after_ms: nil, suspend_after_ms: nil}}}
    Screen.put_settings(off_after_ms: 60_000, suspend_after_ms: 300_000)
    assert_receive {:screen_event, {:display, %{off_after_ms: 60_000, suspend_after_ms: 300_000}}}
    # Not a choice: back to never.
    Screen.put_settings(suspend_after_ms: 1_234)
    assert_receive {:screen_event, {:display, %{suspend_after_ms: nil}}}
  end

  test "runs without a backlight" do
    Application.put_env(:fp3_extras, :backlight_root, Path.join(tmp(), "no-such-dir"))
    on_exit(fn -> Application.delete_env(:fp3_extras, :backlight_root) end)
    start_supervised!(Screen)
    assert Screen.display().brightness == 60
    Screen.toggle()
    wait_for(fn -> Screen.mode() == :off end)
  end
end
