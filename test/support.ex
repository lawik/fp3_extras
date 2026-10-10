defmodule Fp3Extras.TestSupport do
  @moduledoc false
  # Directories of files standing in for sysfs, and a fake amixer.

  @tmp Path.expand("../tmp/test", __DIR__)

  def tmp, do: @tmp

  def fresh_state_dir do
    dir = Application.get_env(:fp3_extras, :state_dir)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  @doc "A fake backlight directory with the FP3's range."
  def fake_backlight(max \\ 4095) do
    dir = Path.join(@tmp, "backlight/panel")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "max_brightness"), "#{max}\n")
    File.write!(Path.join(dir, "brightness"), "0\n")
    File.write!(Path.join(dir, "bl_power"), "0\n")
    dir
  end

  @doc "A fake sysfs root with power, rtc and wakeup entries."
  def fake_sysfs_root do
    root = Path.join(@tmp, "sysfs")
    File.rm_rf!(root)

    for dir <- ~w(sys/power sys/class/rtc/rtc0 sys/class/wakeup/wakeup3 sys/class/wakeup/wakeup7),
        do: File.mkdir_p!(Path.join(root, dir))

    File.write!(Path.join(root, "sys/power/mem_sleep"), "[s2idle]\n")
    File.write!(Path.join(root, "sys/power/state"), "freeze mem\n")
    File.write!(Path.join(root, "sys/class/rtc/rtc0/wakealarm"), "")
    File.write!(Path.join(root, "sys/class/wakeup/wakeup3/name"), "pm8941_pwrkey\n")
    File.write!(Path.join(root, "sys/class/wakeup/wakeup3/event_count"), "2\n")
    File.write!(Path.join(root, "sys/class/wakeup/wakeup7/name"), "rtc0\n")
    File.write!(Path.join(root, "sys/class/wakeup/wakeup7/event_count"), "0\n")
    root
  end

  @doc "A fake power_supply directory: a discharging battery and a charger."
  def fake_power_supply do
    root = Path.join(@tmp, "power_supply")
    File.rm_rf!(root)
    battery = Path.join(root, "qg-battery")
    charger = Path.join(root, "pmi632-charger")
    File.mkdir_p!(battery)
    File.mkdir_p!(charger)
    File.write!(Path.join(battery, "capacity"), "76\n")
    File.write!(Path.join(battery, "status"), "Discharging\n")
    File.write!(Path.join(battery, "voltage_now"), "3900000\n")
    File.write!(Path.join(battery, "current_now"), "-230000\n")
    File.write!(Path.join(charger, "online"), "1\n")
    File.write!(Path.join(charger, "status"), "1\n")
    root
  end

  @doc "Points ex_audio at a fake `amixer` that logs its arguments. Returns the log path."
  def fake_amixer do
    dir = Path.join(@tmp, "bin")
    File.mkdir_p!(dir)
    log = Path.join(dir, "amixer.log")
    File.rm(log)
    fake = Path.join(dir, "amixer")

    File.write!(fake, """
    #!/bin/sh
    echo "$@" >> #{log}
    [ -e #{dir}/fail ] && exit 1
    exit 0
    """)

    File.chmod!(fake, 0o755)
    File.rm(Path.join(dir, "fail"))

    Application.put_env(:ex_audio, :amixer, fake)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:ex_audio, :amixer) end)
    log
  end

  def amixer_log do
    case File.read(Path.join(@tmp, "bin/amixer.log")) do
      {:ok, log} -> log
      _ -> ""
    end
  end

  def wait_for(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      Process.sleep(10)
      fun.()
    end)
    |> Enum.find(fn ok? -> ok? or System.monotonic_time(:millisecond) > deadline end)
    |> Kernel.||(flunk_timeout(fun))
  end

  defp flunk_timeout(fun),
    do: raise(ExUnit.AssertionError, message: "timed out waiting for #{inspect(fun)}")
end
