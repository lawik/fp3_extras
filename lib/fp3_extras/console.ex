defmodule Fp3Extras.Console do
  @moduledoc """
  Keeps the kernel's messages off the panel, and quiet.

  nerves_system_fp3 boots with `console=tty0 loglevel=8 fbcon=rotate:3
  fbcon=font:TER16x32`, so the kernel draws every message on the display
  through fbcon, rotated, in a big font. That's good while booting and
  while nothing else owns the display. Once a DRM application (Emerge)
  has the panel it's a liability: fbcon still renders every message into
  the framebuffer behind the application, and a burst of them stalls
  everything else. The case that showed it: after a resume from suspend
  the camera drivers print two WARN backtraces, which froze the BEAM for
  about eleven seconds with fbcon bound, against about one second with
  it unbound (or with the console log level lowered).

  There are two independent levers:

    * `release_panel/0` unbinds the framebuffer console
      (`/sys/class/vtconsole/vtconN/bind`). Nothing is drawn on the panel
      any more, including the IEx prompt erlinit opens on tty1. Messages
      still go to the log buffer (`dmesg`, RingLogger through
      nerves_logging's kmsg tailer) and to the serial console.
    * `set_loglevel/1` changes the console log level
      (`/proc/sys/kernel/printk`, what `dmesg -n` sets). Messages below
      it aren't written to any console, panel or serial, but stay in the
      log buffer. `quiet/0` sets it to 3 (errors and worse).

  Do the first once the display application is up; the second is a
  matter of taste, as it also quiets the serial console. On a laptop
  neither file exists and both functions do nothing.
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
