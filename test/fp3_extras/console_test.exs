defmodule Fp3Extras.ConsoleTest do
  use ExUnit.Case, async: true

  import Fp3Extras.TestSupport
  alias Fp3Extras.Console

  setup do
    root = Path.join(tmp(), "vtconsole")
    File.rm_rf!(root)

    for {name, display, bound} <- [
          {"vtcon0", "(S) dummy device", "1"},
          {"vtcon1", "(M) frame buffer device", "1"},
          {"vtcon2", "(M) frame buffer device", "0"}
        ] do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "name"), display <> "\n")
      File.write!(Path.join(dir, "bind"), bound <> "\n")
    end

    printk = Path.join(tmp(), "printk")
    File.write!(printk, "8\t4\t1\t7\n")
    %{root: root, printk: printk}
  end

  test "unbinds the bound framebuffer consoles only", %{root: root} do
    assert Console.release_panel(root) == [Path.join(root, "vtcon1")]
    assert File.read!(Path.join(root, "vtcon1/bind")) == "0"
    # The dummy console and the already-unbound one are left alone.
    assert File.read!(Path.join(root, "vtcon0/bind")) == "1\n"
    assert File.read!(Path.join(root, "vtcon2/bind")) == "0\n"
    # A second run finds nothing to do.
    assert Console.release_panel(root) == []
  end

  test "reads and sets the console log level", %{printk: printk} do
    assert {:ok, 8} = Console.loglevel(printk)
    assert :ok = Console.quiet(printk)
    assert {:ok, 3} = Console.loglevel(printk)
    assert :ok = Console.set_loglevel(7, printk)
    assert File.read!(printk) == "7"
  end

  test "does nothing without the files" do
    assert Console.release_panel(Path.join(tmp(), "no-such-dir")) == []
    assert :ok = Console.set_loglevel(3, Path.join(tmp(), "no-such-file"))
    assert {:error, :enoent} = Console.loglevel(Path.join(tmp(), "no-such-file"))
  end
end
