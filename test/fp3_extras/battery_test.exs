defmodule Fp3Extras.BatteryTest do
  use ExUnit.Case, async: true

  import Fp3Extras.TestSupport
  alias Fp3Extras.Battery

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

  test "fields beyond the basics are nil when their files are missing", %{root: root} do
    battery = Battery.read(root: root)

    for key <- ~w(temperature_c health technology design_mah current_avg_a usb_type)a,
        do: assert(Map.fetch!(battery, key) == nil, "#{key} should be nil")

    assert Battery.hours_left(battery) == nil
  end

  test "reads temperature, health, design capacity, average current and USB-C mode",
       %{root: root} do
    full_gauge(root)
    battery = Battery.read(root: root)

    assert_in_delta battery.temperature_c, 28.5, 0.001
    assert battery.health == "Good"
    assert battery.technology == "Li-ion"
    assert battery.design_mah == 3000
    assert_in_delta battery.current_avg_a, -0.25, 0.001
    assert battery.usb_type == "PD"
  end

  test "temperature below zero", %{root: root} do
    write(root, "qg-battery/temp", "-35")
    assert_in_delta Battery.read(root: root).temperature_c, -3.5, 0.001
  end

  test "usb_type is nil when no mode is bracketed", %{root: root} do
    write(
      root,
      "tcpm-source-psy-c440000.qcom,spmi:qcom,pmi632@2:qcom,qpnp-typec/usb_type",
      "C PD PD_DRP"
    )

    assert Battery.read(root: root).usb_type == nil
  end

  test "hours left while discharging", %{root: root} do
    full_gauge(root)
    # 76 % of 3000 mAh at 250 mA.
    assert_in_delta Battery.hours_left(Battery.read(root: root)), 9.12, 0.001
  end

  test "hours to full while charging", %{root: root} do
    full_gauge(root)
    write(root, "qg-battery/status", "Charging")
    write(root, "qg-battery/current_avg", "1000000")
    # The missing 24 % of 3000 mAh at 1000 mA.
    assert_in_delta Battery.hours_left(Battery.read(root: root)), 0.72, 0.001
  end

  test "no estimate without current or without a battery", %{root: root} do
    full_gauge(root)
    write(root, "qg-battery/current_avg", "-400")
    assert Battery.hours_left(Battery.read(root: root)) == nil
    assert Battery.hours_left(nil) == nil
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

  defp full_gauge(root) do
    write(root, "qg-battery/temp", "285")
    write(root, "qg-battery/health", "Good")
    write(root, "qg-battery/technology", "Li-ion")
    write(root, "qg-battery/charge_full_design", "3000000")
    write(root, "qg-battery/current_avg", "-250000")

    write(
      root,
      "tcpm-source-psy-c440000.qcom,spmi:qcom,pmi632@2:qcom,qpnp-typec/usb_type",
      "C [PD] PD_DRP"
    )
  end

  defp write(root, file, value) do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, value <> "\n")
  end
end
