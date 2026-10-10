defmodule Fairphone3Extras.Battery do
  @moduledoc """
  The battery and the charger, from `/sys/class/power_supply`.

  Two supplies matter on the Fairphone 3:

    * `qg-battery` - the PMI632's fuel gauge (QGauge). `voltage_now` and
      `current_now` are live (µV and µA; current is negative while
      discharging). **`capacity` is not**: on this kernel it's the
      open-circuit estimate made at boot and never updates, so it can't
      drive a low-battery warning. Count on voltage, or on coulombs from
      `current_now` over time, until the gauge driver learns better.
    * `pmi632-charger` - the charger. `status` is `Charging`, `Full`,
      `Discharging` or `Not charging`, and `online` says whether USB
      power is present. `status` is also writable: writing `0` suspends
      the USB input, so the phone runs from its battery with the cable
      still attached, and `1` resumes charging. That's the trick behind
      `measure/2`.

  ## Measuring what the phone draws

  Charger input current is noisy and includes what goes into the
  battery, so it says little about the system. With the input suspended,
  `current_now * voltage_now` from the fuel gauge is the system's draw.
  `measure/2` does that for a while and restores charging in an `after`,
  so a crash in the middle doesn't leave the phone on battery.

  Run it in a process that outlives the caller (a `spawn` logging to a
  file) when working over SSH: a dropped SSH channel kills the eval
  process, and `after` blocks don't run in a killed process.

  Numbers from 2026-10-10 on nerves_system_fp3 v0.2.4, idle with the UI
  up, for a sense of scale:

  | State | Draw |
  |---|---|
  | Screen on, idle | about 0.92 W |
  | Backlight off | about 0.90 W |
  | Plus the sensor streams stopped | about 0.76 W |
  | Plus two BEAM schedulers online | about 0.68 W |

  Taking CPU cores offline saved nothing measurable. Suspend to idle is
  the next lever (`Fairphone3Extras.Power`).
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
          power_w: float() | nil
        }

  @doc """
  The battery now. `level` is the fuel gauge's `capacity` (see the
  caveat above), `charging` is true for `Charging` and `Full`, `current_a`
  is negative while discharging, and `power_w` is `voltage * current`,
  negative while discharging. Nil where there's no battery.
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

        %{
          level: level,
          status: status,
          charging: status in ["Charging", "Full"],
          voltage_v: voltage && voltage / 1_000_000,
          current_a: current && current / 1_000_000,
          power_w: voltage && current && voltage * current / 1.0e12
        }
    end
  end

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
  Measures the system's draw: suspends the charger input, samples the
  fuel gauge every `interval_ms` for `duration_ms` (skipping the first
  `settle_ms`, as the current takes a moment to move), then resumes
  charging whatever happens. Returns the mean draw in watts and the
  samples.

      Fairphone3Extras.Battery.measure(30_000)
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

  defp first(opts, pattern) do
    case Path.wildcard(Path.join(opts[:root] || @sysfs, pattern)) do
      [dir | _] -> dir
      [] -> nil
    end
  end

  defp int(dir, name) do
    case Fairphone3Extras.sysfs_int(Path.join(dir, name)) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp str(dir, name) do
    case Fairphone3Extras.sysfs_read(Path.join(dir, name)) do
      {:ok, value} -> value
      _ -> nil
    end
  end
end
