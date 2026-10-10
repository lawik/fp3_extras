defmodule Fp3Extras.Power do
  @moduledoc """
  Suspend and wake.

  The Fairphone 3 suspends to idle only (`/sys/power/mem_sleep` offers
  `s2idle`). Writing `mem` to `/sys/power/state` blocks until the resume.
  It wakes on the power button, the RTC alarm
  (`/sys/class/rtc/rtc0/wakealarm`) and USB.

  `suspend/1` sets the alarm when asked, writes `mem` and returns once
  resumed. Around it:

    * Erlang's monotonic clock and its timers stop in s2idle;
      `System.os_time/0` moves. Read it before and after for the real
      elapsed time.
    * The camera drivers print two WARN backtraces on resume. With fbcon
      bound they stall the system for about ten seconds; see
      `Fp3Extras.Console`.
    * Wi-Fi fails to take the interface down at suspend entry and
      reconnects slowly on some wakes; see `Fp3Extras.WiFi`.

  `Fp3Extras.Sleep` does the display, sensors, console and Wi-Fi around
  this. `:root` is the sysfs root (for tests).
  """

  @sysfs_root "/"

  @typedoc """
  Options: `:wake_after`, seconds until the RTC wakes the phone (none to
  rely on the button or USB); `:rtc`, the RTC's name (`"rtc0"`); `:root`,
  the sysfs root (for tests).
  """
  @type opts :: [wake_after: pos_integer(), rtc: String.t(), root: Path.t()]

  @doc "The sleep states the kernel offers (`[\"s2idle\"]` on the Fairphone 3)."
  @spec mem_sleep(opts()) :: {:ok, [String.t()]} | {:error, term()}
  def mem_sleep(opts \\ []) do
    with {:ok, text} <- File.read(path(opts, "sys/power/mem_sleep")) do
      {:ok, text |> String.replace(["[", "]"], "") |> String.split()}
    end
  end

  @doc "The states `/sys/power/state` accepts (`freeze` and `mem` here)."
  @spec states(opts()) :: {:ok, [String.t()]} | {:error, term()}
  def states(opts \\ []) do
    with {:ok, text} <- File.read(path(opts, "sys/power/state")), do: {:ok, String.split(text)}
  end

  @doc """
  Suspends the phone, and returns after it has resumed with how long it
  was gone by the OS clock, in milliseconds.

  With `wake_after: seconds`, the RTC wakes it then. Anything else that
  wakes the phone (the power button, USB) ends the suspend early, and
  the alarm is cleared on return so it can't fire later. Without a
  `/sys/power/state` (a laptop) it returns `{:error, :enoent}`.
  """
  @spec suspend(opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def suspend(opts \\ []) do
    state = path(opts, "sys/power/state")

    with :ok <- maybe_set_alarm(opts),
         before = System.os_time(:millisecond),
         :ok <- File.write(state, "mem") do
      _ = if opts[:wake_after], do: clear_alarm(opts)
      {:ok, System.os_time(:millisecond) - before}
    end
  end

  @doc """
  Sets the RTC alarm `seconds` from now. The alarm is a one-shot wake
  source for s2idle; `+N` is the sysfs form for "N seconds from now".
  """
  @spec set_alarm(pos_integer(), opts()) :: :ok | {:error, term()}
  def set_alarm(seconds, opts \\ []) when is_integer(seconds) and seconds > 0 do
    alarm = wakealarm(opts)
    # A pending alarm must be cleared before a new one is accepted.
    _ = File.write(alarm, "0")
    File.write(alarm, "+#{seconds}")
  end

  @doc "Clears the RTC alarm."
  @spec clear_alarm(opts()) :: :ok | {:error, term()}
  def clear_alarm(opts \\ []), do: File.write(wakealarm(opts), "0")

  @doc "The pending RTC alarm as Unix seconds, or nil."
  @spec alarm(opts()) :: {:ok, non_neg_integer() | nil} | {:error, term()}
  def alarm(opts \\ []) do
    with {:ok, text} <- File.read(wakealarm(opts)) do
      case Integer.parse(String.trim(text)) do
        {at, _} -> {:ok, at}
        :error -> {:ok, nil}
      end
    end
  end

  @doc """
  The kernel's wakeup sources that have woken it, from
  `/sys/class/wakeup`: `%{name => event_count}` for those with events.
  Which device ended the last suspend is in `dmesg` rather than here.
  """
  @spec wakeups(opts()) :: %{String.t() => non_neg_integer()}
  def wakeups(opts \\ []) do
    for dir <- Path.wildcard(path(opts, "sys/class/wakeup/*")),
        {:ok, name} <- [Fp3Extras.sysfs_read(Path.join(dir, "name"))],
        {:ok, count} <- [Fp3Extras.sysfs_int(Path.join(dir, "event_count"))],
        count > 0,
        into: %{},
        do: {name, count}
  end

  defp maybe_set_alarm(opts) do
    case opts[:wake_after] do
      nil -> :ok
      seconds -> set_alarm(seconds, opts)
    end
  end

  defp wakealarm(opts), do: path(opts, "sys/class/rtc/#{opts[:rtc] || "rtc0"}/wakealarm")

  defp path(opts, rel), do: Path.join(opts[:root] || @sysfs_root, rel)
end
