defmodule Fp3Extras.WiFi do
  @moduledoc """
  Wi-Fi after a suspend, and through one.

  Wi-Fi is the WCNSS core (wcn36xx), its firmware loaded by remoteproc.
  Without a wake-on-wireless trigger, mac80211 takes `wlan0` down at
  suspend and the driver's command fails ("Failed to disable vif: -EIO").
  wpa_supplicant usually reconnects within a second of the wake, but
  sometimes minutes later and once not at all. A reconfigure doesn't help
  when the firmware is stuck.

  `reset/1` restarts the WCNSS remoteproc, reloading the firmware; `wlan0`
  disappears and reappears. `Fp3Extras.Sleep` uses it when VintageNet
  doesn't report a connection in time, and `Fp3Extras.WiFi.PowerManager`
  lets VintageNet's watchdog do the same. The restart hasn't been run on
  a phone yet.

  With a trigger from `wake_on_wireless/2` the association survives the
  suspend and the firmware answers ARP, neighbour discovery and rekeying.
  `:any` wakes on every unicast frame, which on a LAN is every second or
  two. `:magic_packet` stayed asleep through pings but didn't wake on a
  Wake-on-LAN frame in the one test.

  `wait_connected/2` and the power manager need `vintage_net`.
  `wake_on_wireless/2` runs the system's `wpa_cli` against VintageNet's
  control socket.
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

  @doc "Sets wpa_supplicant's `wowlan_triggers`. Takes effect at the next suspend."
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

    VintageNet pets the watchdog on every passed internet check. Power off
    stops the remoteproc, power on starts it.
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
