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
    assert :ok = Leds.torch(true, opts)
    refute File.exists?(opts[:root])
  end
end
