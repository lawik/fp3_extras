defmodule Fp3Extras.VolumeTest do
  # Not async: the level lives in persistent terms shared by the module,
  # and the tests change ex_audio's application env.
  use ExUnit.Case

  import Fp3Extras.TestSupport
  alias Fp3Extras.Volume

  setup do
    fresh_state_dir()
    fake_amixer()
    # A fresh counter and steps for each test.
    for key <- [:ref, :steps, :default], do: :persistent_term.erase({Volume, key})
    :ok
  end

  test "starts at the default, steps within bounds, saves and applies the level" do
    start_supervised!(Volume)
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
    wait_for(fn -> File.read(Path.join(Fp3Extras.state_dir(), "volume")) == {:ok, "0"} end)
  end

  test "comes back at the saved level" do
    File.write!(Path.join(Fp3Extras.state_dir(), "volume"), "4")
    start_supervised!(Volume)
    assert Volume.level() == 4
  end

  test "takes its own control and steps, and applies on ex_audio's card" do
    put_ex_audio_env(:card, 1)
    start_supervised!({Volume, control: "PCM", steps: 8, default: 8})
    assert Volume.level() == 8
    wait_for(fn -> amixer_log() =~ "-c 1 cset name=PCM 255,255" end)
  end

  test "without amixer the level is kept and saved, and applied once it is there" do
    fake = Application.fetch_env!(:ex_audio, :amixer)
    put_ex_audio_env(:amixer, Path.join(tmp(), "bin/no-such-amixer"))
    start_supervised!(Volume)

    assert Volume.set(3) == 3
    assert Volume.level() == 3
    wait_for(fn -> File.read(Path.join(Fp3Extras.state_dir(), "volume")) == {:ok, "3"} end)
    assert amixer_log() == ""

    Application.put_env(:ex_audio, :amixer, fake)
    Volume.reapply()
    # 3 of 16 steps is raw 48 of 255.
    wait_for(fn -> amixer_log() =~ "cset name=Master 48,48" end)
  end

  test "the asound.conf snippet names the control and uses ex_audio's card" do
    assert Volume.asound_conf() =~ ~s(name "Master")
    assert Volume.asound_conf() =~ ~s(slave.pcm "hw:0,0")
    assert Volume.asound_conf(control: "Out", card: 2) =~ ~s(slave.pcm "hw:2,0")

    put_ex_audio_env(:card, 1)
    assert Volume.asound_conf() =~ ~s(slave.pcm "hw:1,0")
  end

  defp put_ex_audio_env(key, value) do
    old = Application.fetch_env(:ex_audio, key)
    Application.put_env(:ex_audio, key, value)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:ex_audio, key, v)
        :error -> Application.delete_env(:ex_audio, key)
      end
    end)
  end
end
