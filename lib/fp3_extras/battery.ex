defmodule Fp3Extras.Battery do
  @moduledoc """
  The battery and charger from `/sys/class/power_supply`.

    * `qg-battery`, the PMI632 fuel gauge. `voltage_now` and `current_now`
      are live (µV, µA, negative while discharging). `capacity` is the
      open-circuit estimate made at boot and never updates, so it can't
      drive a low-battery warning. `current_avg` reads 0.
    * `pmi632-charger`. `status` is `Charging`, `Full`, `Discharging` or
      `Not charging`; `online` says USB power is present. Writing `0` to
      `status` suspends the USB input (the phone runs from battery with
      the cable in), `1` resumes it.
    * `tcpm-source-psy-*`, the USB-C port. `usb_type` brackets the active
      mode (`C`, `PD`).

  ## Measuring the system's draw

  Charger current includes what goes into the battery. With the input
  suspended, `current_now * voltage_now` is the system alone. `measure/2`
  does that and restores charging in an `after`. Over SSH, run it in a
  process that outlives the connection: a dropped channel kills the eval
  process and its `after` doesn't run.

  Idle with a UI up: screen on about 0.92 W, backlight off 0.90 W, sensor
  streams stopped 0.76 W, two BEAM schedulers 0.68 W. Taking cores
  offline saved nothing. Suspend (`Fp3Extras.Power`) is the next lever.
  """

  @sysfs "/sys/class/power_supply"

  @typedoc "Options: `:root`, the power_supply directory (for tests)."
  @type opts :: [root: Path.t()]

  @type t :: %{
          level: non_neg_integer() | nil,
          status: String.t() | nil,
          charging: boolean(),
          voltage_v: float() | nil,
          current_a: float() | nil,
          power_w: float() | nil,
          temperature_c: float() | nil,
          health: String.t() | nil,
          technology: String.t() | nil,
          design_mah: non_neg_integer() | nil,
          current_avg_a: float() | nil,
          usb_type: String.t() | nil
        }

  @doc """
  The battery now, or nil without one. `level` is the gauge's `capacity`
  (see above), `charging` is true for `Charging` and `Full`, `current_a`
  and `power_w` are negative while discharging. `temperature_c` is
  `temp` / 10, `design_mah` is `charge_full_design` / 1000, `usb_type` the
  USB-C port's bracketed mode. A field is nil when its file is missing.
  """
  @spec read(opts()) :: t() | nil
  def read(opts \\ []) do
    case battery_dir(opts) do
      nil ->
        nil

      dir ->
        level = int(dir, "capacity")
        status = str(dir, "status")
        voltage = int(dir, "voltage_now")
        current = int(dir, "current_now")
        temp = int(dir, "temp")
        design = int(dir, "charge_full_design")
        current_avg = int(dir, "current_avg")

        %{
          level: level,
          status: status,
          charging: status in ["Charging", "Full"],
          voltage_v: voltage && voltage / 1_000_000,
          current_a: current && current / 1_000_000,
          power_w: voltage && current && voltage * current / 1.0e12,
          temperature_c: temp && temp / 10,
          health: str(dir, "health"),
          technology: str(dir, "technology"),
          design_mah: design && div(design, 1000),
          current_avg_a: current_avg && current_avg / 1_000_000,
          usb_type: usb_type(opts)
        }
    end
  end

  @doc """
  Hours to full while `Charging`, else hours left: the share of
  `design_mah` that `level` says is left, over `current_avg_a`. Nil under
  a milliamp or with a nil field. Only as good as `level`, which doesn't
  update after boot, so an order of magnitude at best.
  """
  @spec hours_left(t() | nil) :: float() | nil
  def hours_left(%{level: level, status: status, design_mah: design, current_avg_a: avg})
      when is_number(level) and is_number(design) and is_number(avg) do
    current_ma = abs(avg) * 1000
    left_mah = design * level / 100

    cond do
      current_ma < 1 -> nil
      status == "Charging" -> max(design - left_mah, 0) / current_ma
      true -> left_mah / current_ma
    end
  end

  def hours_left(_battery), do: nil

  @doc "Whether USB power is present (the charger's `online`)."
  @spec usb_present?(opts()) :: boolean()
  def usb_present?(opts \\ []) do
    case charger_dir(opts) do
      nil -> false
      dir -> int(dir, "online") == 1
    end
  end

  @doc """
  Suspends or resumes the charger's USB input. With it suspended the
  phone runs from the battery while plugged in.
  """
  @spec charge(boolean(), opts()) :: :ok | {:error, term()}
  def charge(on?, opts \\ []) when is_boolean(on?) do
    case charger_dir(opts) do
      nil -> {:error, :no_charger}
      dir -> File.write(Path.join(dir, "status"), if(on?, do: "1", else: "0"))
    end
  end

  @doc """
  Measures the system's draw: suspends the charger input, waits
  `settle_ms` (3 s), samples the gauge every `interval_ms` (1 s) for
  `duration_ms`, resumes charging whatever happens. Returns the mean in
  watts and the samples.

      Fp3Extras.Battery.measure(30_000)
      #=> {:ok, %{watts: 0.91, samples: [...]}}
  """
  @spec measure(pos_integer(), keyword()) ::
          {:ok, %{watts: float(), samples: [float()]}} | {:error, term()}
  def measure(duration_ms, opts \\ []) do
    interval = opts[:interval_ms] || 1_000
    settle = opts[:settle_ms] || 3_000

    with :ok <- charge(false, opts) do
      try do
        Process.sleep(settle)

        samples =
          Stream.repeatedly(fn ->
            Process.sleep(interval)
            read(opts)
          end)
          |> Enum.take(max(div(duration_ms, interval), 1))
          |> Enum.map(& &1.power_w)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&abs/1)

        case samples do
          [] -> {:error, :no_samples}
          _ -> {:ok, %{watts: Enum.sum(samples) / length(samples), samples: samples}}
        end
      after
        charge(true, opts)
      end
    end
  end

  defp battery_dir(opts), do: first(opts, "qg-battery*")
  defp charger_dir(opts), do: first(opts, "*charger*")

  defp usb_type(opts) do
    with dir when dir != nil <- first(opts, "tcpm-source-psy-*"),
         text when text != nil <- str(dir, "usb_type"),
         [_, active] <- Regex.run(~r/\[([^\]]+)\]/, text) do
      active
    else
      _ -> nil
    end
  end

  defp first(opts, pattern) do
    case Path.wildcard(Path.join(opts[:root] || @sysfs, pattern)) do
      [dir | _] -> dir
      [] -> nil
    end
  end

  defp int(dir, name) do
    case Fp3Extras.sysfs_int(Path.join(dir, name)) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp str(dir, name) do
    case Fp3Extras.sysfs_read(Path.join(dir, name)) do
      {:ok, value} -> value
      _ -> nil
    end
  end
end
