defmodule Fp3Extras.Console do
  @moduledoc """
  Keeps kernel messages off the panel, and quiet.

  The kernel boots with `console=tty0 loglevel=8 fbcon=rotate:3
  fbcon=font:TER16x32`, so fbcon draws every message on the panel. Once a
  DRM client owns the panel, fbcon still renders behind it, and a burst
  stalls the system: the two camera WARN backtraces after every resume
  froze the BEAM for about eleven seconds with fbcon bound, one second
  unbound.

    * `release_panel/0` unbinds the framebuffer console
      (`/sys/class/vtconsole/vtconN/bind`). Nothing is drawn on the panel
      any more, the IEx prompt on tty1 included. Messages still reach
      `dmesg`, RingLogger and the serial console.
    * `set_loglevel/1` sets the console log level
      (`/proc/sys/kernel/printk`); messages below it stay in the log
      buffer only. `quiet/0` sets 3.

  Without the files (a laptop) both do nothing.
  """

  require Logger

  @vtconsoles "/sys/class/vtconsole"
  @printk "/proc/sys/kernel/printk"

  @doc """
  Unbinds every framebuffer console under `root`. Returns the consoles it
  unbound.
  """
  @spec release_panel(Path.t()) :: [Path.t()]
  def release_panel(root \\ @vtconsoles) do
    root
    |> Path.join("vtcon*")
    |> Path.wildcard()
    |> Enum.filter(&framebuffer_console?/1)
    |> Enum.filter(&unbind/1)
  end

  @doc """
  The console log level: messages with a lower priority number (more
  urgent) than this are printed on the consoles. Kernel levels are 0
  (emergency) to 7 (debug); the boot arguments set 8, everything.
  """
  @spec loglevel(Path.t()) :: {:ok, 0..8} | {:error, term()}
  def loglevel(printk \\ @printk) do
    with {:ok, text} <- File.read(printk),
         [current | _] <- String.split(text),
         {level, _} <- Integer.parse(current) do
      {:ok, level}
    else
      {:error, _} = error -> error
      _ -> {:error, :unreadable}
    end
  end

  @doc "Sets the console log level, 0..8. Without the file, does nothing."
  @spec set_loglevel(0..8, Path.t()) :: :ok | {:error, term()}
  def set_loglevel(level, printk \\ @printk) when level in 0..8 do
    if File.exists?(printk), do: File.write(printk, Integer.to_string(level)), else: :ok
  end

  @doc "Console log level 3: errors, critical, alerts and emergencies only."
  @spec quiet(Path.t()) :: :ok | {:error, term()}
  def quiet(printk \\ @printk), do: set_loglevel(3, printk)

  defp framebuffer_console?(vtcon) do
    case File.read(Path.join(vtcon, "name")) do
      {:ok, name} -> String.contains?(name, "frame buffer")
      _ -> false
    end
  end

  defp unbind(vtcon) do
    bind = Path.join(vtcon, "bind")

    case File.read(bind) do
      {:ok, "1\n"} ->
        case File.write(bind, "0") do
          :ok ->
            Logger.info("Unbound the framebuffer console #{vtcon} from the panel")
            true

          {:error, reason} ->
            Logger.warning("Couldn't unbind the framebuffer console #{vtcon}: #{inspect(reason)}")
            false
        end

      _ ->
        false
    end
  end
end
