defmodule Fairphone3Extras.BatteryTest do
  use ExUnit.Case, async: true

  import Fairphone3Extras.TestSupport
  alias Fairphone3Extras.Battery

  setup do
    %{root: fake_power_supply()}
  end

  test "reads the fuel gauge", %{root: root} do
    battery = Battery.read(root: root)
    assert battery.level == 76
    assert battery.status == "Discharging"
    refute battery.charging
    assert_in_delta battery.voltage_v, 3.9, 0.001
    assert_in_delta battery.current_a, -0.23, 0.001
    # Negative while discharging: 3.9 V * 0.23 A.
    assert_in_delta battery.power_w, -0.897, 0.001
    assert Battery.usb_present?(root: root)
  end

  test "nil without a battery" do
    assert Battery.read(root: Path.join(tmp(), "no-such-dir")) == nil
    refute Battery.usb_present?(root: Path.join(tmp(), "no-such-dir"))
  end

  test "measuring suspends the charger input and always restores it", %{root: root} do
    status = Path.join(root, "pmi632-charger/status")

    assert {:ok, %{watts: watts, samples: [_ | _]}} =
             Battery.measure(30, root: root, interval_ms: 10, settle_ms: 0)

    assert_in_delta watts, 0.897, 0.001
    assert File.read!(status) == "1"
  end

  test "measuring restores charging when the gauge can't be read", %{root: root} do
    status = Path.join(root, "pmi632-charger/status")
    File.rm!(Path.join(root, "qg-battery/current_now"))
    assert {:error, :no_samples} = Battery.measure(20, root: root, interval_ms: 10, settle_ms: 0)
    assert File.read!(status) == "1"
  end
end
