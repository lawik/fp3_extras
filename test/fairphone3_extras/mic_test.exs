defmodule Fairphone3Extras.MicTest do
  use ExUnit.Case

  import Fairphone3Extras.TestSupport
  alias Fairphone3Extras.Mic

  setup do
    fresh_state_dir()
    fake_amixer()
    :ok
  end

  test "starts with the top mic off and a mono mic device" do
    start_supervised!({Mic, apply: :alsa})
    refute Mic.secondary?()
    assert Mic.channels() == 1
    assert File.read!(Mic.conf_path()) =~ "channels 1"
    # Startup forces the second port off.
    assert amixer_log() =~ "name=AIF1_CAP Mixer SLIM TX8 off"
  end

  test "the top mic is refused until the kernel supports it" do
    start_supervised!({Mic, apply: :alsa})
    assert {:error, :unsupported} = Mic.set_secondary(true)
    refute Mic.secondary?()
  end

  test "experimental: switching the top mic on routes DMIC2 to TX8 and makes the device stereo" do
    start_supervised!({Mic, apply: :alsa, experimental: true})
    assert :ok = Mic.set_secondary(true)
    assert Mic.channels() == 2
    assert File.read!(Mic.conf_path()) =~ "channels 2"
    assert amixer_log() =~ "name=DMIC MUX8 DMIC2"
    assert amixer_log() =~ "name=AIF1_CAP Mixer SLIM TX8 on"

    assert :ok = Mic.set_secondary(false)
    assert Mic.channels() == 1
  end

  test "a mixer failure changes nothing" do
    start_supervised!({Mic, apply: :alsa, experimental: true})
    File.touch!(Path.join(tmp(), "bin/fail"))
    assert {:error, {"SLIM TX8 MUX", 1, _}} = Mic.set_secondary(true)
    refute Mic.secondary?()
    assert File.read!(Mic.conf_path()) =~ "channels 1"
  end
end
