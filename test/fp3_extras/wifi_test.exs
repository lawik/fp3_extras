defmodule Fp3Extras.WiFiTest do
  use ExUnit.Case, async: true

  import Fp3Extras.TestSupport
  alias Fp3Extras.WiFi

  setup do
    root = Path.join(tmp(), "remoteproc")
    File.rm_rf!(root)

    for {dir, name, state} <- [
          {"remoteproc0", "adsp", "running"},
          {"remoteproc2", "a204000.remoteproc", "running"}
        ] do
      File.mkdir_p!(Path.join(root, dir))
      File.write!(Path.join(root, "#{dir}/name"), name <> "\n")
      File.write!(Path.join(root, "#{dir}/state"), state <> "\n")
    end

    %{root: root}
  end

  test "finds the WCNSS remoteproc by name", %{root: root} do
    assert {dir, "running"} = WiFi.remoteproc(root: root)
    assert Path.basename(dir) == "remoteproc2"
    assert WiFi.remoteproc(root: Path.join(tmp(), "no-such-dir")) == nil
  end

  test "reset stops and starts the WCNSS remoteproc only", %{root: root} do
    assert :ok = WiFi.reset(root: root, settle_ms: 0)
    assert File.read!(Path.join(root, "remoteproc2/state")) == "start"
    assert File.read!(Path.join(root, "remoteproc0/state")) == "running\n"
  end

  test "reset without the remoteproc is an error" do
    assert {:error, :no_remoteproc} = WiFi.reset(root: Path.join(tmp(), "no-such-dir"))
  end

  test "the power manager stops and starts it", %{root: root} do
    {:ok, state} = WiFi.PowerManager.init(ifname: "wlan0", root: root)
    assert {:ok, ^state, _hold} = WiFi.PowerManager.power_off(state)
    assert File.read!(Path.join(root, "remoteproc2/state")) == "stop"

    File.write!(Path.join(root, "remoteproc2/state"), "offline\n")
    assert {:ok, ^state, _hold} = WiFi.PowerManager.power_on(state)
    assert File.read!(Path.join(root, "remoteproc2/state")) == "start"
  end

  test "waiting for the connection needs VintageNet" do
    assert {:error, :no_vintage_net} = WiFi.wait_connected(10)
  end

  test "wake on wireless needs wpa_cli" do
    assert {:error, :no_wpa_cli} =
             WiFi.wake_on_wireless(:any, wpa_cli: Path.join(tmp(), "no-wpa_cli"))
  end
end
