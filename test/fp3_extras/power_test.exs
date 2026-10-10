defmodule Fp3Extras.PowerTest do
  use ExUnit.Case, async: true

  import Fp3Extras.TestSupport
  alias Fp3Extras.Power

  setup do
    %{root: fake_sysfs_root()}
  end

  test "reads the sleep states", %{root: root} do
    assert {:ok, ["s2idle"]} = Power.mem_sleep(root: root)
    assert {:ok, ["freeze", "mem"]} = Power.states(root: root)
  end

  test "sets and clears the RTC alarm", %{root: root} do
    assert :ok = Power.set_alarm(300, root: root)
    assert File.read!(Path.join(root, "sys/class/rtc/rtc0/wakealarm")) == "+300"
    assert :ok = Power.clear_alarm(root: root)
    assert {:ok, 0} = Power.alarm(root: root)
  end

  test "suspends by writing mem, with an alarm that's cleared after", %{root: root} do
    assert {:ok, ms} = Power.suspend(wake_after: 60, root: root)
    assert ms >= 0
    assert File.read!(Path.join(root, "sys/power/state")) == "mem"
    assert File.read!(Path.join(root, "sys/class/rtc/rtc0/wakealarm")) == "0"
  end

  test "fails cleanly without the kernel files" do
    assert {:error, :enoent} = Power.suspend(root: Path.join(tmp(), "no-such-dir"))
  end

  test "lists the wakeup sources that have fired", %{root: root} do
    assert Power.wakeups(root: root) == %{"pm8941_pwrkey" => 2}
  end
end
