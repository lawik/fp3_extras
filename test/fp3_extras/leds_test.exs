defmodule Fp3Extras.LedsTest do
  use ExUnit.Case, async: true

  import Fp3Extras.TestSupport
  alias Fp3Extras.Leds

  setup do
    root = Path.join(tmp(), "leds")
    File.rm_rf!(root)

    for {name, max} <- [{"rgb:status", 511}, {"white:flash-0", 50}, {"white:flash-1", 50}] do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "max_brightness"), "#{max}\n")
      File.write!(Path.join(dir, "brightness"), "0\n")
    end

    File.write!(Path.join([root, "rgb:status", "multi_intensity"]), "0 0 0\n")
    File.write!(Path.join([root, "rgb:status", "trigger"]), "[none] heartbeat pattern\n")
    %{opts: [root: root], root: root}
  end

  defp read(root, led, file), do: File.read!(Path.join([root, led, file]))

  test "lists and finds LEDs by substring", %{opts: opts} do
    assert Leds.list(opts) == ["rgb:status", "white:flash-0", "white:flash-1"]
    assert Leds.find("flash", opts) == "white:flash-0"
    assert Leds.find("nope", opts) == nil
    assert Leds.rgb(opts) == "rgb:status"
    assert Leds.rgb([led: "custom"] ++ opts) == "custom"
    assert Leds.flash(opts) == ["white:flash-0", "white:flash-1"]
    assert Leds.flash([led: "white:flash-1"] ++ opts) == ["white:flash-1"]
  end

  test "reads and writes brightness", %{opts: opts, root: root} do
    assert {:ok, 511} = Leds.max("rgb:status", opts)
    assert :ok = Leds.set("white:flash-0", 7, opts)
    assert {:ok, 7} = Leds.get("white:flash-0", opts)
    assert :ok = Leds.set_percent("white:flash-0", 50, opts)
    assert read(root, "white:flash-0", "brightness") == "25"
    assert :ok = Leds.set_percent("white:flash-0", 0.1, opts)
    assert read(root, "white:flash-0", "brightness") == "1"
    assert :ok = Leds.off("white:flash-0", opts)
    assert read(root, "white:flash-0", "brightness") == "0"
    assert {:error, :enoent} = Leds.max("missing", opts)
  end

  test "sets the notification LED's colour", %{opts: opts, root: root} do
    assert :ok = Leds.set_rgb({255, 128, 0}, opts)
    assert read(root, "rgb:status", "multi_intensity") == "511 256 0"
    assert read(root, "rgb:status", "brightness") == "511"
    assert :ok = Leds.rgb_off(opts)
    assert read(root, "rgb:status", "brightness") == "0"
  end

  test "plays a full-colour pattern of equal steps in the PMIC", %{opts: opts, root: root} do
    assert {:ok, :hardware} = Leds.pattern({0, 0, 255}, [{255, 100}, {0, 100}], opts)
    assert read(root, "rgb:status", "trigger") == "pattern"
    assert read(root, "rgb:status", "repeat") == "-1"
    assert read(root, "rgb:status", "multi_intensity") == "0 0 511"
    # The LUT takes the levels as they are, held then changed at once.
    assert read(root, "rgb:status", "hw_pattern") == "255 100 255 0 0 100 0 0"
    refute File.exists?(Path.join([root, "rgb:status", "pattern"]))

    assert {:ok, :hardware} = Leds.blink({255, 255, 0}, [repeat: :once] ++ opts)
    assert read(root, "rgb:status", "repeat") == "1"
    assert read(root, "rgb:status", "hw_pattern") == "255 500 255 0 0 500 0 0"
  end

  test "plays a mixed colour or uneven steps on the timer, scaled to the LED", %{
    opts: opts,
    root: root
  } do
    assert {:ok, :software} = Leds.pattern({255, 128, 0}, [{255, 100}, {0, 900}], opts)
    assert read(root, "rgb:status", "multi_intensity") == "511 256 0"
    assert read(root, "rgb:status", "pattern") == "511 100 511 0 0 900 0 0"
    refute File.exists?(Path.join([root, "rgb:status", "hw_pattern"]))

    assert {:ok, :software} = Leds.blink({0, 255, 0}, [on_ms: 100, off_ms: 900] ++ opts)

    assert {:error, :not_for_hardware} =
             Leds.pattern({255, 128, 0}, [{255, 100}, {0, 100}], [mode: :hardware] ++ opts)

    assert {:ok, :software} =
             Leds.pattern({0, 0, 255}, [{255, 100}, {0, 100}], [mode: :software] ++ opts)

    assert read(root, "rgb:status", "pattern") == "511 100 511 0 0 100 0 0"
  end

  test "falls back to the timer when the PMIC refuses", %{opts: opts, root: root} do
    File.mkdir_p!(Path.join([root, "rgb:status", "hw_pattern"]))
    assert {:ok, :software} = Leds.pattern({255, 0, 0}, [{255, 100}, {0, 100}], opts)
    assert read(root, "rgb:status", "pattern") == "511 100 511 0 0 100 0 0"

    assert {:error, :eisdir} =
             Leds.pattern({255, 0, 0}, [{255, 100}, {0, 100}], [mode: :hardware] ++ opts)
  end

  test "breathes in equal steps and knows what the PMIC can play", %{opts: opts, root: root} do
    steps = Leds.breathe_steps(2_000, 20)
    assert length(steps) == 20
    assert Enum.all?(steps, &match?({_, 100}, &1))
    assert {0, 100} = hd(steps)
    assert {255, 100} = Enum.at(steps, 10)
    assert Leds.hardware_able?({255, 0, 255}, steps)
    refute Leds.hardware_able?({255, 0, 255}, Leds.breathe_steps(20_000, 20))
    refute Leds.hardware_able?({255, 0, 255}, Leds.breathe_steps(2_000, 65))
    refute Leds.hardware_able?({255, 0, 255}, [{255, 100}])

    assert {:ok, :hardware} = Leds.breathe({255, 255, 255}, opts)
    assert read(root, "rgb:status", "hw_pattern") =~ ~r/^0 100 0 0 6 100 6 0 /
    assert {:ok, :software} = Leds.breathe({255, 255, 255}, [period_ms: 20_000] ++ opts)
  end

  test "rejects bad steps and needs the trigger", %{opts: opts, root: root} do
    assert {:error, :too_few_steps} = Leds.pattern({255, 0, 0}, [{255, 100}], opts)
    assert {:error, :bad_step} = Leds.pattern({255, 0, 0}, [{300, 100}, {0, 100}], opts)
    assert {:error, :bad_step} = Leds.pattern({255, 0, 0}, [{255, 0}, {0, 100}], opts)

    assert {:error, {:bad_mode, :pmic}} =
             Leds.pattern({255, 0, 0}, [{255, 1}, {0, 1}], [mode: :pmic] ++ opts)

    File.write!(Path.join([root, "rgb:status", "trigger"]), "[none] heartbeat\n")
    assert {:error, :no_pattern_trigger} = Leds.pattern({255, 0, 0}, [{255, 100}, {0, 100}], opts)
  end

  test "a colour or off ends the pattern", %{opts: opts, root: root} do
    assert {:ok, :hardware} = Leds.blink({255, 0, 0}, opts)
    assert :ok = Leds.set_rgb({0, 255, 0}, opts)
    assert read(root, "rgb:status", "trigger") == "none"
    # (The real file keeps listing every trigger; the fake one was overwritten.)
    File.write!(Path.join([root, "rgb:status", "trigger"]), "[none] heartbeat pattern\n")
    assert {:ok, :hardware} = Leds.blink({255, 0, 0}, opts)
    assert :ok = Leds.rgb_off(opts)
    assert read(root, "rgb:status", "trigger") == "none"
    assert read(root, "rgb:status", "brightness") == "0"
  end

  test "turns the torch on and off", %{opts: opts, root: root} do
    assert :ok = Leds.torch(true, opts)
    assert read(root, "white:flash-0", "brightness") == "50"
    assert read(root, "white:flash-1", "brightness") == "50"
    assert :ok = Leds.torch(true, [percent: 20] ++ opts)
    assert read(root, "white:flash-1", "brightness") == "10"
    assert :ok = Leds.torch(false, opts)
    assert read(root, "white:flash-0", "brightness") == "0"
    assert read(root, "white:flash-1", "brightness") == "0"
  end

  test "without LEDs, reads fail and writes do nothing" do
    opts = [root: Path.join(tmp(), "no-such-leds")]
    assert Leds.list(opts) == []
    assert Leds.rgb(opts) == nil
    assert Leds.flash(opts) == []
    assert {:error, :no_leds} = Leds.max("rgb:status", opts)
    assert {:error, :no_leds} = Leds.get("rgb:status", opts)
    assert :ok = Leds.set("rgb:status", 1, opts)
    assert :ok = Leds.set_percent("rgb:status", 50, opts)
    assert :ok = Leds.set_rgb({1, 2, 3}, opts)
    assert :ok = Leds.rgb_off(opts)
    assert {:ok, :none} = Leds.blink({255, 0, 0}, opts)
    assert :ok = Leds.torch(true, opts)
    refute File.exists?(opts[:root])
  end
end
