defmodule Fairphone3Extras.BacklightTest do
  use ExUnit.Case, async: true

  import Fairphone3Extras.TestSupport
  alias Fairphone3Extras.Backlight

  setup do
    %{device: fake_backlight()}
  end

  test "maps percent to raw on a 2.2 power curve, and back" do
    assert Backlight.to_raw(0, 4095) == 0
    assert Backlight.to_raw(100, 4095) == 4095
    assert Backlight.to_raw(50, 4095) == 891
    # Anything above black is at least raw 1.
    assert Backlight.to_raw(0.1, 4095) == 1
    assert_in_delta Backlight.to_percent(891, 4095), 50, 0.1
    assert Backlight.to_percent(0, 4095) == 0.0
  end

  test "writes brightness and power to the device", %{device: device} do
    assert :ok = Backlight.set(50, device: device)
    assert File.read!(Path.join(device, "brightness")) == "891"
    assert {:ok, 891} = Backlight.get_raw(device: device)
    assert {:ok, percent} = Backlight.get(device: device)
    assert_in_delta percent, 50, 0.1

    assert :ok = Backlight.power(false, device: device)
    assert File.read!(Path.join(device, "bl_power")) == "4"
    assert {:ok, false} = Backlight.powered?(device: device)
    assert :ok = Backlight.power(true, device: device)
    assert {:ok, true} = Backlight.powered?(device: device)
  end

  test "finds the first device under the backlight root", %{device: device} do
    Application.put_env(:fairphone3_extras, :backlight_root, Path.dirname(device))
    on_exit(fn -> Application.delete_env(:fairphone3_extras, :backlight_root) end)
    assert Backlight.device() == device
    assert {:ok, 4095} = Backlight.max_raw()
  end

  test "without a backlight, reads fail and writes do nothing" do
    Application.put_env(:fairphone3_extras, :backlight_root, Path.join(tmp(), "no-such-dir"))
    on_exit(fn -> Application.delete_env(:fairphone3_extras, :backlight_root) end)
    assert Backlight.device() == nil
    assert {:error, :no_backlight} = Backlight.get()
    assert :ok = Backlight.set(50)
    assert :ok = Backlight.power(false)
  end
end
