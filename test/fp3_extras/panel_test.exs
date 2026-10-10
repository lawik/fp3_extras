defmodule Fp3Extras.PanelTest do
  use ExUnit.Case, async: true

  import Fp3Extras.TestSupport
  alias Fp3Extras.Panel

  test "blanks and unblanks through fbdev" do
    path = Path.join(tmp(), "fb0_blank")
    File.write!(path, "0\n")
    assert {:ok, false} = Panel.blanked?(path)
    assert :ok = Panel.blank(true, path)
    assert File.read!(path) == "4"
    assert {:ok, true} = Panel.blanked?(path)
    assert :ok = Panel.blank(false, path)
    assert {:ok, false} = Panel.blanked?(path)
  end

  test "does nothing without fbdev" do
    path = Path.join(tmp(), "no-such-file")
    assert :ok = Panel.blank(true, path)
    assert {:error, :enoent} = Panel.blanked?(path)
  end
end
