defmodule Fp3Extras.WiFi do
  @moduledoc """
  Getting Wi-Fi back after a suspend, and keeping it through one.

  The Fairphone 3's Wi-Fi is the WCNSS core (wcn36xx) running firmware
  loaded by remoteproc. Around a suspend to idle, two things were seen on
  nerves_system_fp3 v0.2.4:

    * **Tearing the interface down fails.** Without a wake-on-wireless
      trigger, mac80211 takes `wlan0` down on suspend, and wcn36xx's
      command to the firmware fails: "Failed to disable vif: -EIO" in the
      log, at suspend entry. After the resume wpa_supplicant reconnects on
      its own, usually within a second, but on one wake it took eleven
      minutes and on another the interface sat disconnected. That's
      wpa_supplicant backing off against a firmware that answers scans
      badly, and a reconfigure doesn't help when the firmware itself is
      stuck.
    * **Keeping the interface up avoids it.** With a wake-on-wireless
      trigger set (`wake_on_wireless/2`), the driver leaves the association
      in place, hands ARP, IPv6 neighbour discovery and group rekeying to
      the firmware, and the error doesn't happen. The catch is the trigger
      itself: `:any` wakes the phone on any unicast frame, which on a LAN
      with Tailscale, mDNS and friends is every second or two, and
      `:magic_packet` didn't wake the phone in the one test made (it did
      stay asleep through pings, as it should).

  So the recovery is: wait for VintageNet to report the connection, and if
  it doesn't come back in time, restart the WCNSS remoteproc (`reset/1`),
  which reloads the firmware and makes `wlan0` disappear and reappear.
  `Fp3Extras.Sleep` does that after every wake. The same reset serves
  `Fp3Extras.WiFi.PowerManager`, a `VintageNet.PowerManager` for `wlan0`,
  so VintageNet's own watchdog can do it whenever the link is down for too
  long, suspend or not.

  The remoteproc restart hasn't been exercised on the phone yet, only the
  stop and start files it writes have been read. Treat the first run as
  the test.

  `wait_connected/2` and the power manager need `vintage_net`, which this
  library doesn't depend on; they're no-ops without it. `wake_on_wireless/2`
  runs `wpa_cli`, which the Nerves system has, against VintageNet's control
  socket directory.
  """

  require Logger

  @remoteproc_root "/sys/class/remoteproc"
  @wcnss "a204000.remoteproc"
  @wpa_cli "/usr/sbin/wpa_cli"
  @wpa_ctrl "/tmp/vintage_net/wpa_supplicant"

  @typedoc """
  Options: `:root`, the remoteproc class directory (for tests); `:name`,
  the remoteproc's name (`"a204000.remoteproc"`, the WCNSS core);
  `:settle_ms`, how long to leave it stopped (2 s).
  """
  @type opts :: [root: Path.t(), name: String.t(), settle_ms: non_neg_integer()]

  @doc """
  The WCNSS remoteproc's directory and state, or nil when there's none
  (a laptop).
  """
  @spec remoteproc(opts()) :: {Path.t(), String.t()} | nil
  def remoteproc(opts \\ []) do
    name = opts[:name] || @wcnss

    (opts[:root] || @remoteproc_root)
    |> Path.join("remoteproc*")
    |> Path.wildcard()
    |> Enum.find_value(fn dir ->
      with {:ok, ^name} <- Fp3Extras.sysfs_read(Path.join(dir, "name")),
           {:ok, state} <- Fp3Extras.sysfs_read(Path.join(dir, "state")) do
        {dir, state}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Restarts the Wi-Fi firmware: stops the WCNSS remoteproc, waits
  `settle_ms`, starts it again. `wlan0` goes away and comes back, and
  wpa_supplicant (through VintageNet) reconnects. Returns `:ok` once the
  start was accepted; the interface takes a few seconds more.
  """
  @spec reset(opts()) :: :ok | {:error, term()}
  def reset(opts \\ []) do
    case remoteproc(opts) do
      nil ->
        {:error, :no_remoteproc}

      {dir, _state} ->
        state = Path.join(dir, "state")
        Logger.warning("Restarting the WCNSS remoteproc to get Wi-Fi back")

        with :ok <- stop(state),
             :ok <- Process.sleep(opts[:settle_ms] || 2_000) && File.write(state, "start") do
          :ok
        end
    end
  end

  # A remoteproc that's already offline refuses "stop" with EINVAL; that's fine.
  defp stop(state) do
    case File.write(state, "stop") do
      :ok -> :ok
      {:error, :einval} -> :ok
      error -> error
    end
  end

  @doc """
  Waits up to `timeout_ms` for VintageNet to report `ifname` connected
  to the internet (or at least to a LAN with `lan: true`). Returns
  `{:ok, ms}` with how long it took, `{:error, :timeout}`, or
  `{:error, :no_vintage_net}` on a laptop.
  """
  @spec wait_connected(non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :timeout | :no_vintage_net}
  def wait_connected(timeout_ms, opts \\ []) do
    ifname = opts[:ifname] || "wlan0"
    good = if opts[:lan], do: [:lan, :internet], else: [:internet]
    poll = opts[:poll_ms] || 250

    if Code.ensure_loaded?(VintageNet) do
      started = System.monotonic_time(:millisecond)

      Stream.repeatedly(fn -> connection(ifname) end)
      |> Enum.reduce_while({:error, :timeout}, fn state, acc ->
        elapsed = System.monotonic_time(:millisecond) - started

        cond do
          state in good -> {:halt, {:ok, elapsed}}
          elapsed >= timeout_ms -> {:halt, acc}
          true -> Process.sleep(poll) && {:cont, acc}
        end
      end)
    else
      {:error, :no_vintage_net}
    end
  end

  @doc false
  def connection(ifname), do: apply(VintageNet, :get, [["interface", ifname, "connection"]])

  @typedoc """
  Wake-on-wireless triggers: `:any` (any unicast frame addressed to the
  phone), `:magic_packet` (a Wake-on-LAN frame), or `:off`.
  """
  @type trigger :: :any | :magic_packet | :off

  @doc """
  Sets wpa_supplicant's `wowlan_triggers`, which it passes to the driver
  through nl80211. Takes effect at the next suspend. See the module doc
  for what each trigger did in practice.
  """
  @spec wake_on_wireless(trigger(), keyword()) :: :ok | {:error, term()}
  def wake_on_wireless(trigger, opts \\ []) when trigger in [:any, :magic_packet, :off] do
    wpa_cli = opts[:wpa_cli] || @wpa_cli
    ctrl = opts[:ctrl_dir] || @wpa_ctrl
    ifname = opts[:ifname] || "wlan0"

    value =
      case trigger do
        :any -> "any"
        :magic_packet -> "magic_packet"
        :off -> ""
      end

    if File.exists?(wpa_cli) do
      case System.cmd(wpa_cli, ["-p", ctrl, "-i", ifname, "set", "wowlan_triggers", value],
             stderr_to_stdout: true
           ) do
        {"OK\n", 0} -> :ok
        {out, _} -> {:error, String.trim(out)}
      end
    else
      {:error, :no_wpa_cli}
    end
  end

  defmodule PowerManager do
    @moduledoc """
    A `VintageNet.PowerManager` for `wlan0` that restarts the WCNSS
    remoteproc when VintageNet's watchdog decides the link has been down
    too long.

        config :vintage_net,
          power_managers: [{Fp3Extras.WiFi.PowerManager, [ifname: "wlan0", watchdog_timeout: 60_000]}]

    VintageNet pets the watchdog itself whenever the interface passes its
    internet check, so nothing else is needed. Power off stops the
    remoteproc, power on starts it; VintageNet waits for `wlan0` to
    reappear before configuring it. `Fp3Extras.Sleep` can also ask for a
    reset directly after a wake, through `VintageNet.PowerManager.PMControl.force_reset/1`,
    when the power manager is configured.
    """

    if Code.ensure_loaded?(VintageNet.PowerManager), do: @behaviour(VintageNet.PowerManager)

    require Logger

    # Give the firmware and wpa_supplicant time before the watchdog can bite again.
    @power_on_hold_time 30_000
    @time_to_power_off 500
    @min_power_off_time 2_000

    def init(args) do
      {:ok, %{ifname: Keyword.fetch!(args, :ifname), opts: Keyword.take(args, [:root, :name])}}
    end

    def power_on(state) do
      case Fp3Extras.WiFi.remoteproc(state.opts) do
        {dir, "offline"} ->
          Logger.info("Starting the WCNSS remoteproc for #{state.ifname}")
          _ = File.write(Path.join(dir, "state"), "start")

        _ ->
          :ok
      end

      {:ok, state, @power_on_hold_time}
    end

    def start_powering_off(state), do: {:ok, state, @time_to_power_off}

    def power_off(state) do
      case Fp3Extras.WiFi.remoteproc(state.opts) do
        {dir, "running"} ->
          Logger.warning("Stopping the WCNSS remoteproc for #{state.ifname}")
          _ = File.write(Path.join(dir, "state"), "stop")

        _ ->
          :ok
      end

      {:ok, state, @min_power_off_time}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end
end
