defmodule Fairphone3Extras.ScreenTest do
  use ExUnit.Case

  import Fairphone3Extras.TestSupport
  alias Fairphone3Extras.Screen

  defmodule FakeLight do
    @behaviour Fairphone3Extras.LightSensor.Source
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

    path = Path.join(Fairphone3Extras.state_dir(), "display.json")
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

  test "runs without a backlight" do
    Application.put_env(:fairphone3_extras, :backlight_root, Path.join(tmp(), "no-such-dir"))
    on_exit(fn -> Application.delete_env(:fairphone3_extras, :backlight_root) end)
    start_supervised!(Screen)
    assert Screen.display().brightness == 60
    Screen.toggle()
    wait_for(fn -> Screen.mode() == :off end)
  end
end
