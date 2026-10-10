defmodule Fairphone3Extras.ButtonsTest do
  use ExUnit.Case, async: true

  alias Fairphone3Extras.Buttons

  test "tells a touchscreen from a button device by what it reports" do
    touch = %{report_info: [ev_abs: [abs_mt_position_x: %{}, abs_mt_position_y: %{}]]}
    keys = %{report_info: [ev_key: [:key_volumeup, :key_volumedown]]}
    power = %{report_info: [ev_key: [:key_power]]}
    jack = %{report_info: [ev_sw: [:sw_headphone_insert]]}
    assert Buttons.kind(touch) == :touchscreen
    assert Buttons.kind(keys) == :buttons
    assert Buttons.kind(power) == :buttons
    assert Buttons.kind(jack) == nil
  end

  test "stops without input_event" do
    Process.flag(:trap_exit, true)
    assert {:error, :no_input_event} = Buttons.start_link(name: :buttons_test)
  end
end
