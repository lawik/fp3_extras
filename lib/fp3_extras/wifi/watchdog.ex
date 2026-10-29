defmodule Fp3Extras.WiFi.Watchdog do
  @moduledoc """
  Restarts the Wi-Fi firmware when it stops transmitting.

  After many hours up, the WCNSS firmware can stop putting frames on the
  air while still receiving: scans find the access point, every
  authentication times out, and the remoteproc stays `running`, so the
  kernel's crash recovery never runs and wpa_supplicant retries forever.
  `Fp3Extras.WiFi.reset/1` brings it back; see the hardware guide.

  The watchdog restarts the firmware when all of these hold:

  1. `wlan0` is configured with VintageNetWiFi and at least one network.
  2. Its connection has been `:disconnected` for `:grace_ms` (4 min).
  3. A configured network is in the scan results at `:min_signal_dbm`
     (−75) or better, so the phone isn't just out of range.
  4. The kernel logged a line of the jam within `:evidence_ms` (15 min),
     and after the last restart: an authentication or association timing
     out, or wcn36xx failing to flush its transmit queues or getting an
     event it doesn't know (`:kernel_lines`, regular expressions). A
     wrong password fails later, in the handshake, so it doesn't count.
     `evidence: false` drops this condition.

  Restarts are at least `:min_interval_ms` (10 min) apart, the interval
  doubling after each one not followed by a connection within
  `:verify_ms` (60 s). After `:max_restarts` (3) of those in a row it
  gives up, logs an error and runs `:on_give_up` (a 0-arity function, in
  a process of its own), until the connection comes back or the
  configuration changes. Each restart is logged as a warning with what
  set it off. Bluetooth runs on the same core and restarts too.

  The durations are on the monotonic clock, which stops during a suspend
  (`Fp3Extras.Sleep` sees to Wi-Fi after a wake), so they count time
  awake.

      children = [Fp3Extras.WiFi.Watchdog]

  Kernel lines arrive through a `:logger` handler on `nerves_logging`'s
  kernel messages (`application: :"$kmsg"`); `kernel_log: false` leaves
  it out. Without VintageNet, on a laptop, it waits for property changes
  that never come. `:reset` replaces the restart, a 0-arity function
  returning `:ok` or `{:error, reason}`; `:root`, `:name` and
  `:settle_ms` go to `Fp3Extras.WiFi.reset/1`.
  """

  use GenServer

  require Logger

  alias Fp3Extras.WiFi

  @handler :fp3_extras_wifi_watchdog

  # The VintageNet properties watched, under ["interface", ifname].
  @properties [
    connection: ["connection"],
    config: ["config"],
    access_points: ["wifi", "access_points"]
  ]

  @defaults [
    ifname: "wlan0",
    grace_ms: 240_000,
    min_signal_dbm: -75,
    evidence: true,
    evidence_ms: 900_000,
    kernel_lines: [
      "(authentication|association) with \\S+ timed out",
      "wcn36xx: ERROR Failed to flush hardware tx queues",
      "wcn36xx: ERROR SMD_EVENT \\(\\d+\\) not supported"
    ],
    kernel_log: true,
    min_interval_ms: 600_000,
    verify_ms: 60_000,
    max_restarts: 3,
    restart_timeout_ms: 120_000,
    check_ms: 30_000,
    on_give_up: nil
  ]

  @doc "Starts the watchdog. See the module doc for the options; `:name` defaults to the module."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  What the watchdog sees: its `phase` (`:watching`, `:restarting`,
  `:verifying`, `:given_up`), the connection, how long it's been
  disconnected, the last kernel line of the jam, the restarts so far and
  the failed ones in a row, and, while watching, its `verdict`: `{:ok, _}`
  when a restart is due, or `{:wait, reason}`.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl GenServer
  def init(opts) do
    opts = @defaults |> Keyword.merge(opts) |> Map.new()
    Process.flag(:trap_exit, true)
    if opts.kernel_log, do: add_log_handler(opts.kernel_lines)

    state =
      watch(%{
        opts: opts,
        ifname: opts.ifname,
        connection: :disconnected,
        config: nil,
        access_points: [],
        disconnected_at: now(),
        evidence: nil,
        phase: :watching,
        task: nil,
        restart_started: nil,
        restarted_at: nil,
        verify_until: nil,
        restarts: 0,
        failures: 0
      })

    schedule_check(state)
    {:ok, state}
  end

  # Subscribes before reading, so no change falls in between.
  defp watch(state) do
    if Code.ensure_loaded?(VintageNet) do
      Enum.reduce(@properties, state, fn {key, path}, acc ->
        property = ["interface", acc.ifname | path]
        apply(VintageNet, :subscribe, [property])
        put(acc, key, apply(VintageNet, :get, [property]), now())
      end)
    else
      state
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    now = now()

    status = %{
      phase: state.phase,
      connection: state.connection,
      disconnected_ms: state.disconnected_at && now - state.disconnected_at,
      last_kernel_line: state.evidence && elem(state.evidence, 1),
      restarts: state.restarts,
      failures: state.failures,
      verdict: if(state.phase == :watching, do: verdict(state, now))
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_info(
        {VintageNet, ["interface", ifname | path], _old, value, _meta},
        %{ifname: ifname} = state
      ) do
    case List.keyfind(@properties, path, 1) do
      {key, _path} -> {:noreply, put(state, key, value, now())}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:kernel_log, line}, state), do: {:noreply, %{state | evidence: {now(), line}}}

  def handle_info(:check, state) do
    schedule_check(state)
    {:noreply, check(state, now())}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, restarted(state, result, now())}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, failed(state, {:crashed, reason}, now())}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.opts.kernel_log, do: :logger.remove_handler(@handler)
    :ok
  end

  defp put(state, :connection, value, now) do
    if value in [:lan, :internet] do
      if state.phase == :verifying do
        Logger.info(
          "[wifi] #{state.ifname} is back (#{value}) #{now - state.restarted_at} ms after the firmware restart"
        )
      end

      phase = if state.phase == :restarting, do: :restarting, else: :watching
      %{state | connection: value, disconnected_at: nil, failures: 0, phase: phase}
    else
      %{state | connection: value || :disconnected, disconnected_at: state.disconnected_at || now}
    end
  end

  # A new configuration is a fresh start for the count.
  defp put(%{config: value} = state, :config, value, _now), do: state

  defp put(state, :config, value, _now) do
    phase = if state.phase == :given_up, do: :watching, else: state.phase
    %{state | config: value, failures: 0, phase: phase}
  end

  defp put(state, :access_points, value, _now), do: %{state | access_points: value || []}

  defp check(%{phase: :watching} = state, now) do
    case verdict(state, now) do
      {:ok, why} -> restart(state, why, now)
      {:wait, _reason} -> state
    end
  end

  defp check(%{phase: :restarting} = state, now) do
    if now - state.restart_started >= state.opts.restart_timeout_ms do
      case Task.shutdown(state.task, :brutal_kill) do
        {:ok, result} -> restarted(state, result, now)
        _ -> failed(state, :timeout, now)
      end
    else
      state
    end
  end

  defp check(%{phase: :verifying} = state, now) do
    if now >= state.verify_until,
      do: failed(state, :no_connection, state.restarted_at),
      else: state
  end

  defp check(%{phase: :given_up} = state, _now), do: state

  # Whether the firmware is due a restart: {:ok, why} or {:wait, reason}.
  defp verdict(state, now) do
    opts = state.opts
    ssids = configured_ssids(state.config)

    with :ok <- need(ssids != [], :no_network),
         :ok <- need(state.disconnected_at != nil, :connected),
         disconnected_ms = now - state.disconnected_at,
         :ok <- need(disconnected_ms >= opts.grace_ms, :grace),
         {:ok, ap} <- strongest(state.access_points, ssids, opts.min_signal_dbm),
         {:ok, line} <- evidence(state, now),
         :ok <-
           need(
             state.restarted_at == nil or now - state.restarted_at >= interval(state),
             :backoff
           ) do
      {:ok, %{disconnected_ms: disconnected_ms, ap: ap, kernel_line: line}}
    end
  end

  defp need(true, _reason), do: :ok
  defp need(false, reason), do: {:wait, reason}

  defp configured_ssids(%{type: VintageNetWiFi, vintage_net_wifi: %{networks: networks}})
       when is_list(networks),
       do: for(%{ssid: ssid} when is_binary(ssid) and ssid != "" <- networks, do: ssid)

  defp configured_ssids(_config), do: []

  defp strongest(access_points, ssids, min_dbm) do
    access_points
    |> Enum.filter(fn ap ->
      ap.ssid in ssids and is_integer(ap.signal_dbm) and ap.signal_dbm >= min_dbm
    end)
    |> Enum.max_by(& &1.signal_dbm, fn -> nil end)
    |> case do
      nil -> {:wait, :no_access_point}
      ap -> {:ok, ap}
    end
  end

  # A kernel line from before the last restart says nothing about now.
  defp evidence(%{opts: %{evidence: false}}, _now), do: {:ok, nil}

  defp evidence(%{evidence: {at, line}} = state, now) do
    if now - at <= state.opts.evidence_ms and
         (state.restarted_at == nil or at > state.restarted_at),
       do: {:ok, line},
       else: {:wait, :no_kernel_line}
  end

  defp evidence(_state, _now), do: {:wait, :no_kernel_line}

  defp interval(state), do: state.opts.min_interval_ms * Integer.pow(2, state.failures)

  defp restart(state, why, now) do
    %{ap: ap} = why

    Logger.warning(
      "[wifi] #{state.ifname} disconnected for #{div(why.disconnected_ms, 1000)} s with " <>
        "#{ap.ssid} (#{Map.get(ap, :bssid)}, #{Map.get(ap, :frequency)} MHz) at #{ap.signal_dbm} dBm; " <>
        "last kernel line #{inspect(why.kernel_line)}; WCNSS #{inspect(remoteproc_state(state))}. " <>
        "Restarting the firmware (#{state.failures + 1} of #{state.opts.max_restarts})"
    )

    %{
      state
      | phase: :restarting,
        task: Task.async(reset_fun(state.opts)),
        restart_started: now,
        restarts: state.restarts + 1
    }
  end

  defp reset_fun(%{reset: reset}), do: reset

  defp reset_fun(opts) do
    reset_opts = opts |> Map.take([:root, :name, :settle_ms]) |> Keyword.new()
    fn -> WiFi.reset(reset_opts) end
  end

  defp remoteproc_state(state) do
    case state.opts |> Map.take([:root, :name]) |> Keyword.new() |> WiFi.remoteproc() do
      {_dir, rproc_state} -> rproc_state
      nil -> nil
    end
  end

  defp restarted(state, :ok, now) do
    Logger.info(
      "[wifi] WCNSS restarted in #{now - state.restart_started} ms; waiting for #{state.ifname}"
    )

    state = %{state | task: nil, restarted_at: now}

    if state.connection in [:lan, :internet],
      do: %{state | phase: :watching, failures: 0},
      else: %{state | phase: :verifying, verify_until: now + state.opts.verify_ms}
  end

  defp restarted(state, error, now), do: failed(state, error, now)

  defp failed(state, reason, ended_at) do
    failures = state.failures + 1
    state = %{state | task: nil, restarted_at: ended_at, failures: failures, phase: :watching}

    if failures >= state.opts.max_restarts do
      Logger.error(
        "[wifi] giving up on #{state.ifname}: #{failures} firmware restarts in a row " <>
          "didn't bring it back (last: #{inspect(reason)}). Waiting for a connection or a new configuration"
      )

      if give_up = state.opts.on_give_up, do: Task.start(give_up)
      %{state | phase: :given_up}
    else
      Logger.warning(
        "[wifi] the firmware restart didn't bring #{state.ifname} back (#{inspect(reason)}); " <>
          "next one no sooner than #{div(interval(state), 1000)} s"
      )

      state
    end
  end

  defp schedule_check(state), do: Process.send_after(self(), :check, state.opts.check_ms)

  defp now, do: System.monotonic_time(:millisecond)

  defp add_log_handler(kernel_lines) do
    config = %{target: self(), patterns: Enum.map(kernel_lines, &Regex.compile!/1)}
    _ = :logger.remove_handler(@handler)
    :ok = :logger.add_handler(@handler, __MODULE__.KernelLog, %{level: :info, config: config})
  end

  defmodule KernelLog do
    @moduledoc false
    # A :logger handler that hands the watchdog the kernel lines matching
    # its patterns. It runs in the process that logs, nerves_logging's
    # kmsg tailer for kernel lines, so it only looks at those.

    def log(%{msg: {:string, text}, meta: %{application: :"$kmsg"}}, %{config: config}) do
      line = IO.chardata_to_string(text)

      if Enum.any?(config.patterns, &Regex.match?(&1, line)),
        do: send(config.target, {:kernel_log, line})

      :ok
    end

    def log(_event, _config), do: :ok
  end
end
