defmodule Fp3Extras.MicTest do
  # Not async: the tests change ex_audio's application env.
  use ExUnit.Case

  import Fp3Extras.TestSupport
  alias Fp3Extras.Mic

  setup do
    fresh_state_dir()
    fake_amixer()
    :ok
  end

  test "starts with the top mic off and a mono mic device" do
    start_supervised!(Mic)
    refute Mic.secondary?()
    assert Mic.channels() == 1
    assert File.read!(Mic.conf_path()) =~ "channels 1"
    assert File.read!(Mic.conf_path()) =~ ~s(pcm "hw:0,1")
    # Startup forces the second port off.
    assert amixer_log() =~ "-c 0 cset name=AIF1_CAP Mixer SLIM TX8 off"
  end

  test "switching the top mic on routes DMIC2 to TX8 and makes the device stereo" do
    start_supervised!(Mic)
    assert :ok = Mic.set_secondary(true)
    assert Mic.channels() == 2
    assert File.read!(Mic.conf_path()) =~ "channels 2"
    assert amixer_log() =~ "name=DMIC MUX8 DMIC2"
    assert amixer_log() =~ "name=AIF1_CAP Mixer SLIM TX8 on"

    assert :ok = Mic.set_secondary(false)
    assert Mic.channels() == 1
  end

  test "a mixer failure changes nothing" do
    start_supervised!(Mic)
    File.touch!(Path.join(tmp(), "bin/fail"))
    assert {:error, {"SLIM TX8 MUX", {1, _output}}} = Mic.set_secondary(true)
    refute Mic.secondary?()
    assert File.read!(Mic.conf_path()) =~ "channels 1"
  end

  test "without amixer the top mic can't be switched on" do
    Application.put_env(:ex_audio, :amixer, Path.join(tmp(), "bin/no-such-amixer"))
    start_supervised!(Mic)
    assert {:error, {"SLIM TX8 MUX", :enoent}} = Mic.set_secondary(true)
    refute Mic.secondary?()
  end

  test "the mic device is on ex_audio's card" do
    Application.put_env(:ex_audio, :card, 1)
    on_exit(fn -> Application.delete_env(:ex_audio, :card) end)
    start_supervised!(Mic)
    assert File.read!(Mic.conf_path()) =~ ~s(pcm "hw:1,1")
    assert amixer_log() =~ "-c 1 cset"
  end
end
