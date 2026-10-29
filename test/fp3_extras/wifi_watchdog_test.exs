defmodule Fp3Extras.WiFi.WatchdogTest do
  # The kernel log handler is global.
  use ExUnit.Case, async: false

  require Logger

  alias Fp3Extras.WiFi.Watchdog

  @moduletag :capture_log

  @config %{
    type: VintageNetWiFi,
    vintage_net_wifi: %{networks: [%{ssid: "Kontoret", key_mgmt: :wpa_psk, psk: "secret12"}]},
    ipv4: %{method: :dhcp}
  }
  @ap %{
    bssid: "60:45:cb:8b:bf:a0",
    ssid: "Kontoret",
    frequency: 2447,
    signal_dbm: -42,
    signal_percent: 94
  }
  @auth_timeout "wlan0: authentication with 60:45:cb:8b:bf:a0 timed out"

  # A watchdog that checks every 5 ms with no grace period and no wait
  # between restarts, whose firmware restart tells the test.
  defp start(opts \\ []) do
    test = self()

    defaults = [
      name: nil,
      kernel_log: false,
      grace_ms: 0,
      check_ms: 5,
      min_interval_ms: 0,
      verify_ms: 50,
      reset: fn ->
        send(test, :reset)
        :ok
      end
    ]

    start_supervised!(
      Supervisor.child_spec({Watchdog, Keyword.merge(defaults, opts)}, id: make_ref())
    )
  end

  # The status once the watchdog has the restart's result, which can
  # arrive after the test's next message.
  defp settled_status(watchdog) do
    case Watchdog.status(watchdog) do
      %{phase: :restarting} -> Process.sleep(5) && settled_status(watchdog)
      status -> status
    end
  end

  defp property(watchdog, path, value),
    do: send(watchdog, {VintageNet, ["interface", "wlan0" | path], nil, value, %{}})

  # Kontoret close by, wlan0 disconnected, authentication timing out.
  defp jam(watchdog, aps \\ [@ap], config \\ @config) do
    property(watchdog, ["config"], config)
    property(watchdog, ["wifi", "access_points"], aps)
    property(watchdog, ["connection"], :disconnected)
    send(watchdog, {:kernel_log, @auth_timeout})
  end

  test "restarts the firmware when the network is there but nothing gets through" do
    jam(start())
    assert_receive :reset
  end

  test "waits out the grace period" do
    watchdog = start(grace_ms: 60_000)
    jam(watchdog)
    refute_receive :reset, 50
    assert %{verdict: {:wait, :grace}} = Watchdog.status(watchdog)
  end

  test "leaves it alone out of range" do
    watchdog = start()
    jam(watchdog, [%{@ap | signal_dbm: -85}, %{@ap | ssid: "Grannen"}])
    refute_receive :reset, 50
    assert %{verdict: {:wait, :no_access_point}} = Watchdog.status(watchdog)
  end

  test "leaves it alone without a network or while connected" do
    watchdog = start()
    jam(watchdog, [@ap], put_in(@config.vintage_net_wifi.networks, []))
    refute_receive :reset, 50
    assert %{verdict: {:wait, :no_network}} = Watchdog.status(watchdog)

    jam(watchdog, [@ap], %{type: VintageNet.Technology.Null})
    refute_receive :reset, 50

    watchdog = start()
    property(watchdog, ["config"], @config)
    property(watchdog, ["wifi", "access_points"], [@ap])
    property(watchdog, ["connection"], :internet)
    send(watchdog, {:kernel_log, @auth_timeout})
    refute_receive :reset, 50
    assert %{verdict: {:wait, :connected}} = Watchdog.status(watchdog)
  end

  test "a wrong password isn't a jam, unless the kernel lines aren't asked for" do
    watchdog = start()
    property(watchdog, ["config"], @config)
    property(watchdog, ["wifi", "access_points"], [@ap])
    property(watchdog, ["connection"], :disconnected)
    refute_receive :reset, 50
    assert %{verdict: {:wait, :no_kernel_line}} = Watchdog.status(watchdog)

    watchdog = start(evidence: false)
    property(watchdog, ["config"], @config)
    property(watchdog, ["wifi", "access_points"], [@ap])
    assert_receive :reset
  end

  test "kernel lines reach it through the logger" do
    watchdog = start(kernel_log: true)
    property(watchdog, ["config"], @config)
    property(watchdog, ["wifi", "access_points"], [@ap])
    Logger.error("wcn36xx: ERROR Failed to flush hardware tx queues")
    refute_receive :reset, 50

    Logger.error("wcn36xx: ERROR Failed to flush hardware tx queues", application: :"$kmsg")
    assert_receive :reset

    assert %{last_kernel_line: "wcn36xx: ERROR Failed to flush hardware tx queues"} =
             Watchdog.status(watchdog)
  end

  test "a connection after the restart clears the count" do
    watchdog = start(verify_ms: 60_000)
    jam(watchdog)
    assert_receive :reset
    property(watchdog, ["connection"], :internet)

    assert %{phase: :watching, connection: :internet, restarts: 1, failures: 0} =
             settled_status(watchdog)
  end

  test "another restart needs a kernel line from after the last one" do
    watchdog = start(verify_ms: 10)
    jam(watchdog)
    assert_receive :reset
    refute_receive :reset, 50
    assert %{failures: 1, verdict: {:wait, :no_kernel_line}} = Watchdog.status(watchdog)

    send(watchdog, {:kernel_log, @auth_timeout})
    assert_receive :reset
  end

  test "backs off, gives up, and starts over on a connection" do
    test = self()

    watchdog =
      start(
        evidence: false,
        verify_ms: 5,
        min_interval_ms: 20,
        max_restarts: 3,
        on_give_up: fn -> send(test, :gave_up) end
      )

    jam(watchdog)
    assert_receive :reset
    first = System.monotonic_time(:millisecond)
    assert_receive :reset, 500
    second = System.monotonic_time(:millisecond)
    assert_receive :reset, 500
    third = System.monotonic_time(:millisecond)

    # 20 ms doubled after one failed restart, doubled again after two.
    assert second - first >= 40
    assert third - second >= 80

    assert_receive :gave_up, 500
    refute_receive :reset, 100
    assert %{phase: :given_up, restarts: 3, failures: 3} = Watchdog.status(watchdog)

    property(watchdog, ["connection"], :internet)
    property(watchdog, ["connection"], :disconnected)
    assert_receive :reset
  end

  test "a restart that fails or hangs counts" do
    test = self()

    watchdog =
      start(
        evidence: false,
        max_restarts: 1,
        reset: fn -> {:error, :no_remoteproc} end,
        on_give_up: fn -> send(test, :gave_up) end
      )

    jam(watchdog)
    assert_receive :gave_up

    watchdog =
      start(
        evidence: false,
        max_restarts: 1,
        restart_timeout_ms: 20,
        reset: fn -> Process.sleep(:infinity) end,
        on_give_up: fn -> send(test, :gave_up) end
      )

    jam(watchdog)
    assert_receive :gave_up, 500
    assert %{phase: :given_up, restarts: 1} = Watchdog.status(watchdog)
  end
end
