defmodule Fp3Extras.Sleep do
  @moduledoc """
  A whole sleep: quiet the phone, suspend it, and put it back together
  after the wake.

  `Fp3Extras.Power.suspend/1` is the one write that suspends the kernel.
  Everything around it is what was learned the hard way on
  nerves_system_fp3 v0.2.4, and `sleep/1` does it in order:

  1. **The application's `:before` hook.** Turn the display off and stop
     rendering first. The one hang seen in a day of suspend cycles came
     with the GPU mid-frame at suspend entry; blanking first costs
     nothing and leaves nothing in flight.
  2. **Stop the sensor streams** (`stop_sensors/1`). The ADSP streams the
     accelerometer at 200 Hz (the driver ignores a lower rate), and the
     gyro, magnetometer and proximity alongside, into readers that hold
     the IIO devices open. Writing `0` to each device's `buffer/enable`
     stops the stream at the ADSP while the readers stay blocked on
     their open file; `1` resumes it on the same file descriptor. No
     process is touched. Awake, the streams cost about 140 mW and wake
     the cores a thousand times a second.
  3. **Take the kernel console off the panel**
     (`Fp3Extras.Console.release_panel/0`, idempotent). After every
     resume the camera drivers print two WARN backtraces, and with fbcon
     bound drawing them stalled the BEAM for about ten seconds; unbound,
     about one.
  4. **Suspend** with the RTC alarm when `:wake_after` is given, noting
     the wakeup sources before and after to say what woke the phone.
  5. **Restart the sensor streams** that were running.
  6. **The application's `:after` hook**, with what's known so far.
  7. **Wait for Wi-Fi.** wcn36xx fails to take the interface down at
     suspend entry ("Failed to disable vif: -EIO") and the reconnect
     after the wake takes anywhere from a second to minutes. `sleep/1`
     waits `:wifi_timeout_ms` for VintageNet to report the connection
     and, failing that, restarts the Wi-Fi firmware
     (`Fp3Extras.WiFi.reset/1`) and waits once more.

  The result says how long the phone was gone by the wall clock, how
  little Erlang's monotonic clock moved meanwhile (it stops in s2idle, so
  every timer is late by the difference), what woke it, and what Wi-Fi
  did. Keep the hooks short: the `:before` hook runs with everything
  still awake, the `:after` hook before Wi-Fi is back.

  On a laptop nothing exists: `sleep/1` returns `{:error, :enoent}` from
  the suspend write, after running the `:before` hook and before the
  `:after` one.

  ## Wake sources

  What ends a suspend on the Fairphone 3: the power button, the RTC
  alarm, the USB cable and charger, and the battery gauge's own events.
  Not the touchscreen or the volume keys (no `wakeup-source` in the
  device tree), not the modem, and Wi-Fi only with a wake-on-wireless
  trigger (`Fp3Extras.WiFi.wake_on_wireless/2`). The power button's
  press is also delivered to the application as a key event after the
  wake, so a `Fp3Extras.Buttons` `on_power_tap` fires; decide there
  whether a wake should toggle the screen.

  ## A policy

      # Screen's been off a while and nothing holds it awake:
      {:ok, wake} = Fp3Extras.Sleep.sleep(
        wake_after: 600,
        before: fn -> MyPhone.UI.blank() end,
        after: fn _ -> MyPhone.UI.unblank_if(wake_by_button?) end
      )
      # wake.woke_by is :rtc for the timer: do what's due and sleep again;
      # :pwrkey or :usb means someone wants the phone.
  """

  require Logger

  alias Fp3Extras.{Console, Power, WiFi}

  @iio_root "/sys/bus/iio/devices"

  @typedoc """
  What a sleep came back with: `slept_ms` by the wall clock,
  `monotonic_ms` by Erlang's clock (the difference is how late every
  timer now is), `woke_by` (`:rtc`, `:pwrkey`, `:usb`, `:charger`,
  `:battery`, `:other` or `:unknown`), `sensors` (the IIO devices that
  were streaming and are again), and `wifi` (`{:ok, ms}` once connected,
  `{:reset, ms}` if the firmware had to be restarted first, `{:error, _}`
  if it never came back or there's no VintageNet).
  """
  @type wake :: %{
          slept_ms: non_neg_integer(),
          monotonic_ms: non_neg_integer(),
          woke_by: atom(),
          sensors: [Path.t()],
          wifi: {:ok, non_neg_integer()} | {:reset, non_neg_integer()} | {:error, term()}
        }

  @typedoc """
  Options: `:wake_after` seconds for the RTC alarm (none to wait for the
  button or USB); `:before` and `:after` hooks (the latter gets the
  partial wake map); `:sensors` false to leave the streams running;
  `:wifi_timeout_ms` to wait for the connection (20 s; 0 skips Wi-Fi);
  `:wifi_reset` false to never restart the firmware; and `:root`,
  `:iio_root`, `:remoteproc_root` for tests.
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
