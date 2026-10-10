defmodule Fp3Extras.VibratorTest do
  # Changes the :rumble application env.
  use ExUnit.Case, async: false

  import Fp3Extras.TestSupport
  alias Fp3Extras.Vibrator

  setup do
    dir = Path.join(tmp(), "rumble")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    log = Path.join(dir, "rumble.log")
    fake = Path.join(dir, "rumble")

    File.write!(fake, """
    #!/bin/sh
    echo "$@" >> #{log}
    [ -e #{dir}/fail ] && { echo "rumble: no input device with FF_RUMBLE found"; exit 1; }
    exit 0
    """)

    File.chmod!(fake, 0o755)
    Application.put_env(:fp3_extras, :rumble, fake)
    on_exit(fn -> Application.delete_env(:fp3_extras, :rumble) end)
    %{dir: dir, log: log}
  end

  defp calls(log), do: log |> File.read!() |> String.split("\n", trim: true)

  test "runs rumble with the duration, strength and device", %{log: log} do
    assert Vibrator.available?()
    assert :ok = Vibrator.rumble(300)
    assert :ok = Vibrator.rumble(50, strength: 20_000, device: "/dev/input/event2")
    assert calls(log) == ["300", "-d /dev/input/event2 50 20000"]
  end

  test "plays a pattern in order", %{log: log} do
    assert :ok = Vibrator.pattern([{100, 10}, 200, {50, 0}], strength: 1000)
    assert calls(log) == ["100 1000", "200 1000", "50 1000"]
  end

  test "reports the tool's failure and stops a pattern", %{dir: dir, log: log} do
    File.write!(Path.join(dir, "fail"), "")
    assert {:error, {:rumble, 1, "rumble: no input device" <> _}} = Vibrator.rumble(100)
    assert {:error, {:rumble, 1, _}} = Vibrator.pattern([100, 200])
    assert calls(log) == ["100", "100"]
  end

  test "rejects durations and strengths the tool would" do
    assert_raise FunctionClauseError, fn -> Vibrator.rumble(0) end
    assert_raise FunctionClauseError, fn -> Vibrator.rumble(10_001) end
    assert_raise ArgumentError, fn -> Vibrator.rumble(100, strength: 0) end
  end

  test "without the tool, returns :enoent" do
    Application.put_env(:fp3_extras, :rumble, Path.join(tmp(), "no-such-rumble"))
    refute Vibrator.available?()
    assert {:error, :enoent} = Vibrator.rumble(100)
    assert {:error, :enoent} = Vibrator.pattern([100])
  end
end
