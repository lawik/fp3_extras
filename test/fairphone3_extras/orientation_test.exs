defmodule Fairphone3Extras.OrientationTest do
  use ExUnit.Case

  import Fairphone3Extras.TestSupport
  alias Fairphone3Extras.Orientation

  setup do
    fresh_state_dir()
    :ok
  end

  test "classifies readings in the screen's axes" do
    assert Orientation.classify(%{x: 0, y: 9.8}) == :portrait
    assert Orientation.classify(%{x: 9.8, y: 0}) == :landscape_left
    assert Orientation.classify(%{x: -9.8, y: 0}) == :landscape_right
    assert Orientation.classify(%{x: 0, y: -9.8}) == :upside_down
    # Lying flat, and on the diagonal: no say.
    assert Orientation.classify(%{x: 0.5, y: 0.5}) == nil
    assert Orientation.classify(%{x: 6.9, y: 6.9}) == nil
  end

  test "maps the FP3's turned sensor onto the screen" do
    # Held upright the FP3's sensor reads +9.8 on x.
    assert Orientation.to_screen_axes(%{x: 9.8, y: 0.1, z: 0.3}) == %{x: 0.1, y: 9.8}
    assert Orientation.to_screen_axes(%{x: 1, y: 2}, x: {:x, -1}, y: {:y, 1}) == %{x: -1, y: 2}
  end

  test "without a sensor, auto is portrait and the locked modes work, and the mode is saved" do
    me = self()
    start_supervised!({Orientation, notify: &send(me, {:orientation, &1})})
    assert_receive {:orientation, %{orientation: :portrait, mode: :auto, sensor: false}}

    Orientation.put_mode(:landscape)
    assert_receive {:orientation, %{orientation: :landscape_left, mode: :landscape}}
    assert Orientation.current().orientation == :landscape_left

    stop_supervised!(Orientation)
    start_supervised!(Orientation)
    assert Orientation.current().mode == :landscape
  end
end
