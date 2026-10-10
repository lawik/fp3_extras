defmodule Fp3Extras.SleepTest do
  use ExUnit.Case, async: true

  import Fp3Extras.TestSupport
  alias Fp3Extras.Sleep

  # Our own tree, as the Power tests clear the shared one under us.
  setup do
    root = Path.join(tmp(), "sleep-sysfs")
    File.rm_rf!(root)

    for dir <- ~w(sys/power sys/class/rtc/rtc0 sys/class/wakeup/wakeup3),
        do: File.mkdir_p!(Path.join(root, dir))

    File.write!(Path.join(root, "sys/power/state"), "freeze mem\n")
    File.write!(Path.join(root, "sys/class/rtc/rtc0/wakealarm"), "")
    File.write!(Path.join(root, "sys/class/wakeup/wakeup3/name"), "pm8941_pwrkey\n")
    File.write!(Path.join(root, "sys/class/wakeup/wakeup3/event_count"), "2\n")

    iio = Path.join(root, "sys/bus/iio/devices")

    for {dir, name, enabled} <- [
          {"iio:device0", "pmic-adc", "0"},
          {"iio:device2", "qcom-smgr-accel", "1"},
          {"iio:device3", "qcom-smgr-prox", "0"},
          {"iio:device4", "qcom-smgr-gyro", "1"}
        ] do
      File.mkdir_p!(Path.join(iio, "#{dir}/buffer"))
      File.write!(Path.join(iio, "#{dir}/name"), name <> "\n")
      File.write!(Path.join(iio, "#{dir}/buffer/enable"), enabled <> "\n")
    end

    vtconsole = Path.join(root, "sys/class/vtconsole/vtcon1")
    File.mkdir_p!(vtconsole)
    File.write!(Path.join(vtconsole, "name"), "(M) frame buffer device\n")
    File.write!(Path.join(vtconsole, "bind"), "1\n")

    %{
      root: root,
      iio: iio,
      opts: [
        root: root,
        iio_root: iio,
        vtconsole_root: Path.join(root, "sys/class/vtconsole"),
        wifi_timeout_ms: 0
      ]
    }
  end

  defp enabled?(iio, dev), do: File.read!(Path.join(iio, "#{dev}/buffer/enable")) =~ "1"

  test "stops only the running ADSP streams and restarts them", %{iio: iio} do
    stopped = Sleep.stop_sensors(iio)
    assert Enum.map(stopped, &Path.basename/1) == ["iio:device2", "iio:device4"]
    refute enabled?(iio, "iio:device2")
    refute enabled?(iio, "iio:device4")
    # The ADC isn't a sensor stream, and prox was already off.
    assert File.read!(Path.join(iio, "iio:device0/buffer/enable")) == "0\n"

    assert :ok = Sleep.start_sensors(stopped)
    assert enabled?(iio, "iio:device2")
    assert enabled?(iio, "iio:device4")
  end

  test "a sleep runs the hooks around the suspend and restores everything", %{
    root: root,
    iio: iio,
    opts: opts
  } do
    test = self()
    before = fn -> send(test, {:before, enabled?(iio, "iio:device2")}) end
    after_hook = fn wake -> send(test, {:after, wake}) end

    assert {:ok, wake} = Sleep.sleep([wake_after: 30, before: before, after: after_hook] ++ opts)

    # The hook ran while the streams were still on; the streams were off
    # for the suspend and are back.
    assert_received {:before, true}
    assert_received {:after, %{woke_by: :unknown, wifi: {:error, :pending}}}
    assert wake.wifi == {:error, :skipped}
    assert Enum.map(wake.sensors, &Path.basename/1) == ["iio:device2", "iio:device4"]
    assert enabled?(iio, "iio:device2")
    assert File.read!(Path.join(root, "sys/power/state")) == "mem"
    assert File.read!(Path.join(root, "sys/class/rtc/rtc0/wakealarm")) == "0"
    assert File.read!(Path.join(root, "sys/class/vtconsole/vtcon1/bind")) == "0"
  end

  test "names what woke the phone from the wakeup counts" do
    before = %{"pm8941_pwrkey" => 2, "rtc0" => 5, "pmi632-charger" => 700}
    assert Sleep.woke_by(before, %{before | "pm8941_pwrkey" => 3}) == :pwrkey
    assert Sleep.woke_by(before, %{before | "rtc0" => 6}) == :rtc
    assert Sleep.woke_by(before, Map.put(before, "alarmtimer.0.auto", 1)) == :rtc
    # USB brings the charger along; the cable wins.
    assert Sleep.woke_by(before, %{before | "pmi632-charger" => 701} |> Map.put("7000000.usb", 1)) ==
             :usb

    assert Sleep.woke_by(before, %{before | "pmi632-charger" => 701}) == :charger
    # The button beats the alarm when both are counted.
    assert Sleep.woke_by(before, %{before | "pm8941_pwrkey" => 3, "rtc0" => 6}) == :pwrkey
    assert Sleep.woke_by(before, Map.put(before, "mmc1", 1)) == :other
    assert Sleep.woke_by(before, before) == :unknown
  end

  test "without the kernel files the streams are restarted and the error returned", %{
    iio: iio,
    opts: opts
  } do
    opts = Keyword.put(opts, :root, Path.join(tmp(), "no-such-dir"))
    assert {:error, :enoent} = Sleep.sleep(opts)
    assert enabled?(iio, "iio:device2")
  end
end
