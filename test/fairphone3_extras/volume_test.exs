defmodule Fairphone3Extras.VolumeTest do
  # Not async: the level lives in persistent terms shared by the module.
  use ExUnit.Case

  import Fairphone3Extras.TestSupport
  alias Fairphone3Extras.Volume

  setup do
    fresh_state_dir()
    fake_amixer()
    # A fresh counter and steps for each test.
    for key <- [:ref, :steps, :default], do: :persistent_term.erase({Volume, key})
    :ok
  end

  test "starts at the default, steps within bounds, saves and applies the level" do
    start_supervised!({Volume, apply: :alsa})
    assert Volume.level() == 10
    assert Volume.steps() == 16
    # 10 of 16 steps is raw 159 of 255.
    wait_for(fn -> amixer_log() =~ "-c 0 cset name=Master 159,159" end)

    assert Volume.up() == 11
    assert Volume.set(100) == 16
    wait_for(fn -> amixer_log() =~ "cset name=Master 255,255" end)

    assert Volume.down() == 15
    assert Volume.set(-3) == 0
    wait_for(fn -> amixer_log() =~ "cset name=Master 0,0" end)
    wait_for(fn -> File.read(Path.join(Fairphone3Extras.state_dir(), "volume")) == {:ok, "0"} end)
  end

  test "comes back at the saved level" do
    File.write!(Path.join(Fairphone3Extras.state_dir(), "volume"), "4")
    start_supervised!({Volume, apply: :none})
    assert Volume.level() == 4
  end

  test "takes its own control, card and steps" do
    start_supervised!({Volume, apply: :alsa, control: "PCM", card: 1, steps: 8, default: 8})
    assert Volume.level() == 8
    wait_for(fn -> amixer_log() =~ "-c 1 cset name=PCM 255,255" end)
  end

  test "the asound.conf snippet names the control" do
    assert Volume.asound_conf() =~ ~s(name "Master")
    assert Volume.asound_conf(control: "Out", card: 2) =~ ~s(slave.pcm "hw:2,0")
  end
end
