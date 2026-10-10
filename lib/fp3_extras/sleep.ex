defmodule Fp3Extras.Sleep do
  @moduledoc """
  A whole sleep: quiet the phone, suspend it, put it back together.

  `sleep/1`, in order:

  1. The `:before` hook: turn the display off, stop rendering. The one
     hang seen came with the GPU mid-frame at suspend entry.
  2. `stop_sensors/1`: `0` into `buffer/enable` of each ADSP IIO device.
     The accelerometer streams at 200 Hz whatever rate is asked, about
     140 mW and a thousand core wakeups a second. Readers stay blocked on
     their open file and resume on `1`.
  3. `Fp3Extras.Console.release_panel/0`, so the resume's WARN backtraces
     don't stall the BEAM for ten seconds.
  4. `Fp3Extras.Power.suspend/1`, with the RTC alarm if `:wake_after`,
     noting wakeup sources before and after to say what woke the phone.
  5. Restart the sensor streams.
  6. The `:after` hook, with the wake so far.
  7. Wait `:wifi_timeout_ms` for VintageNet to report the connection;
     failing that, `Fp3Extras.WiFi.reset/1` and wait again.

  The result says how long the phone was gone by the wall clock, how
  little the monotonic clock moved (every timer is late by the
  difference), what woke it, and what Wi-Fi did. On a laptop `sleep/1`
  returns `{:error, :enoent}` after the `:before` hook.

  ## Wake sources

  The power button, the RTC alarm, USB and the charger, the battery gauge.
  Not the touchscreen or volume keys (no `wakeup-source` in the device
  tree), not the modem, and Wi-Fi only with
  `Fp3Extras.WiFi.wake_on_wireless/2`. The power button's press is also
  delivered as a key event after the wake, so `on_power_tap` fires.

      {:ok, wake} = Fp3Extras.Sleep.sleep(wake_after: 600, before: &MyUI.blank/0)
      # wake.woke_by: :rtc means do what's due and sleep again;
      # :pwrkey or :usb means someone wants the phone.
  """

  require Logger

  alias Fp3Extras.{Console, Power, WiFi}

  @iio_root "/sys/bus/iio/devices"

  @typedoc """
  `slept_ms` by the wall clock, `monotonic_ms` by Erlang's clock,
  `woke_by` (`:rtc`, `:pwrkey`, `:usb`, `:charger`, `:battery`, `:other`,
  `:unknown`), `sensors` (the IIO devices stopped and restarted), `wifi`
  (`{:ok, ms}`, `{:reset, ms}` after a firmware restart, or `{:error, _}`).
  """
  @type wake :: %{
          slept_ms: non_neg_integer(),
          monotonic_ms: non_neg_integer(),
          woke_by: atom(),
          sensors: [Path.t()],
          wifi: {:ok, non_neg_integer()} | {:reset, non_neg_integer()} | {:error, term()}
        }

  @typedoc """
  `:wake_after` seconds for the RTC alarm; `:before` and `:after` hooks
  (the latter gets the partial wake); `:sensors` false leaves the streams
  running; `:wifi_timeout_ms` (20 s; 0 skips Wi-Fi); `:wifi_reset` false
  never restarts the firmware; `:root`, `:iio_root`, `:remoteproc_root`
  for tests.
  """
  @type opts :: keyword()

  @doc "Quiets the phone, suspends it, and brings it back. See the module doc."
  @spec sleep(opts()) :: {:ok, wake()} | {:error, term()}
  def sleep(opts \\ []) do
    before = opts[:before] || fn -> :ok end
    after_hook = opts[:after] || fn _ -> :ok end
    power_opts = Keyword.take(opts, [:wake_after, :rtc, :root])
    iio = opts[:iio_root] || @iio_root

    before.()
    sensors = if opts[:sensors] == false, do: [], else: stop_sensors(iio)
    _ = Console.release_panel(opts[:vtconsole_root] || "/sys/class/vtconsole")

    wakeups_before = Power.wakeups(power_opts)
    monotonic_before = System.monotonic_time(:millisecond)

    case Power.suspend(power_opts) do
      {:ok, slept_ms} ->
        monotonic_ms = System.monotonic_time(:millisecond) - monotonic_before
        woke_by = woke_by(wakeups_before, Power.wakeups(power_opts))
        start_sensors(sensors)

        wake = %{
          slept_ms: slept_ms,
          monotonic_ms: monotonic_ms,
          woke_by: woke_by,
          sensors: sensors,
          wifi: {:error, :pending}
        }

        Logger.info(
          "Woke after #{slept_ms} ms (#{monotonic_ms} ms by the monotonic clock) by #{woke_by}"
        )

        after_hook.(wake)
        {:ok, %{wake | wifi: recover_wifi(opts)}}

      {:error, _} = error ->
        start_sensors(sensors)
        error
    end
  end

  @doc """
  Stops the ADSP sensor streams: writes `0` to `buffer/enable` of every
  IIO device named `qcom-smgr-*` that has its buffer on. Returns those
  devices, for `start_sensors/1`. Readers blocked on the devices stay
  blocked and resume when the buffers are re-enabled.
  """
  @spec stop_sensors(Path.t()) :: [Path.t()]
  def stop_sensors(iio_root \\ @iio_root) do
    iio_root
    |> Path.join("iio:device*")
    |> Path.wildcard()
    |> Enum.filter(&smgr_device?/1)
    |> Enum.filter(fn dev ->
      Fp3Extras.sysfs_read(Path.join(dev, "buffer/enable")) == {:ok, "1"}
    end)
    |> Enum.filter(fn dev -> File.write(Path.join(dev, "buffer/enable"), "0") == :ok end)
  end

  @doc "Re-enables the buffers `stop_sensors/1` turned off."
  @spec start_sensors([Path.t()]) :: :ok
  def start_sensors(devices) do
    Enum.each(devices, fn dev ->
      case File.write(Path.join(dev, "buffer/enable"), "1") do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Couldn't restart the sensor stream #{dev}: #{inspect(reason)}")
      end
    end)
  end

  defp smgr_device?(dev) do
    case Fp3Extras.sysfs_read(Path.join(dev, "name")) do
      {:ok, "qcom-smgr-" <> _} -> true
      _ -> false
    end
  end

  @doc false
  # The wakeup source whose event count grew, mapped to something an
  # application can switch on. Several can fire at once (USB brings the
  # charger and the Type-C port along); the first in this order wins.
  def woke_by(before, after_wake) do
    fired =
      after_wake
      |> Enum.filter(fn {name, count} -> count > Map.get(before, name, 0) end)
      |> Enum.map(&elem(&1, 0))

    Enum.find_value(
      [
        {~r/pwrkey/, :pwrkey},
        {~r/rtc|alarmtimer/, :rtc},
        {~r/\.usb$|typec/, :usb},
        {~r/charger/, :charger},
        {~r/battery/, :battery}
      ],
      if(fired == [], do: :unknown, else: :other),
      fn {pattern, reason} -> if Enum.any?(fired, &Regex.match?(pattern, &1)), do: reason end
    )
  end

  defp recover_wifi(opts) do
    timeout = opts[:wifi_timeout_ms] || 20_000
    wait_opts = Keyword.take(opts, [:ifname])
    reset? = opts[:wifi_reset] != false

    if timeout == 0 do
      {:error, :skipped}
    else
      case WiFi.wait_connected(timeout, wait_opts) do
        {:ok, ms} -> {:ok, ms}
        {:error, :timeout} when reset? -> reset_wifi(opts, timeout, wait_opts)
        {:error, _} = error -> error
      end
    end
  end

  defp reset_wifi(opts, timeout, wait_opts) do
    started = System.monotonic_time(:millisecond)
    reset_opts = if root = opts[:remoteproc_root], do: [root: root], else: []

    with :ok <- WiFi.reset(reset_opts),
         {:ok, _} <- WiFi.wait_connected(timeout, wait_opts) do
      {:reset, System.monotonic_time(:millisecond) - started}
    else
      {:error, reason} -> {:error, {:reset_failed, reason}}
    end
  end
end
