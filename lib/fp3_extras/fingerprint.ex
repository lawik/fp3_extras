defmodule Fp3Extras.Fingerprint do
  @moduledoc """
  Experiment: can the rear fingerprint sensor act as a touch button?

  The sensor is an Elan part on an SPI bus (BLSP2 QUP3, `spi_7` at
  0x7af7000, GPIO 135-138) that TrustZone owns: the mainline device tree
  lists those pins in `gpio-reserved-ranges`, and reading them, or the
  controller, from Linux most likely faults into TrustZone and reboots
  the phone. Even Android's kernel driver (`elan_fp_qcom_tee`) never
  touches SPI; all sensor I/O happens in a QSEE trusted application
  (`fingerprint.mdt`) that the vendor HAL drives through qseecom. What
  Linux does own are the three sideband lines that driver drives:

    * GPIO 90 - sensor VDD enable (low at boot: the sensor is off)
    * GPIO 140 - reset, active low
    * GPIO 48 - interrupt from the sensor, rising edge on Android

  `watch/0` powers the sensor, pulses reset the way the Android driver
  does, and logs every edge on GPIO 48. If the chip raised its IRQ on
  finger contact without any SPI setup, touches would show up here.

  **Result on 2026-10-10: nothing.** GPIO 48 reads low with the internal
  pull-up, pull-down or no pull, sensor powered or not, and never moved
  on touches or on reset pulses. Something on that net holds it low, and
  the chip raises no interrupt without SPI configuration it can only get
  from the TrustZone app. Kept as a harness in case a different reset or
  power sequence turns out to matter, and because GPIO 90 is a power
  lever: the sensor is off unless something turns it on.

  The way forward, if any, is through TrustZone: see
  `Fp3Extras.TEE.QSEECom`. Needs `circuits_gpio`.
  """

  use GenServer
  require Logger

  @compile {:no_warn_undefined, Circuits.GPIO}

  @chip "gpiochip0"
  @vdd 90
  @reset 140
  @irq 48

  @doc "The GPIO lines, for reference."
  def lines, do: %{chip: @chip, vdd: @vdd, reset: @reset, irq: @irq}

  @doc "Power the sensor, reset it and start logging edges on GPIO 48."
  def watch, do: GenServer.start(__MODULE__, [], name: __MODULE__)

  @doc "Power the sensor down and release the GPIO lines."
  def off do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  @doc "Edges seen so far, newest first, as `{monotonic_ns, value}`."
  def events, do: GenServer.call(__MODULE__, :events)

  @doc "Current level of the IRQ line."
  def irq, do: GenServer.call(__MODULE__, :irq)

  @doc "Pulse reset again (low 5 ms, then 50 ms to settle)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def init(_) do
    if not Code.ensure_loaded?(Circuits.GPIO) do
      {:stop, :no_circuits_gpio}
    else
      with {:ok, vdd} <- Circuits.GPIO.open({@chip, @vdd}, :output, initial_value: 1),
           {:ok, rst} <- Circuits.GPIO.open({@chip, @reset}, :output, initial_value: 1),
           {:ok, irq} <- Circuits.GPIO.open({@chip, @irq}, :input, pull_mode: :pulldown),
           :ok <- Circuits.GPIO.set_interrupts(irq, :both) do
        Process.sleep(10)
        pulse_reset(rst)

        Logger.info("[fingerprint] sensor powered, irq line is #{Circuits.GPIO.read(irq)}")
        {:ok, %{vdd: vdd, rst: rst, irq: irq, events: []}}
      else
        error ->
          Logger.error("[fingerprint] could not open GPIO lines: #{inspect(error)}")
          {:stop, error}
      end
    end
  end

  @impl GenServer
  def handle_call(:events, _from, state), do: {:reply, state.events, state}
  def handle_call(:irq, _from, state), do: {:reply, Circuits.GPIO.read(state.irq), state}

  def handle_call(:reset, _from, state) do
    pulse_reset(state.rst)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:circuits_gpio, _spec, ts, value}, state) do
    Logger.info("[fingerprint] irq -> #{value}")
    {:noreply, %{state | events: [{ts, value} | state.events]}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Circuits.GPIO.write(state.vdd, 0)
    Enum.each([state.irq, state.rst, state.vdd], &Circuits.GPIO.close/1)
    Logger.info("[fingerprint] sensor powered down")
  end

  # Same timing as the Android driver's elan_reset().
  defp pulse_reset(rst) do
    Circuits.GPIO.write(rst, 0)
    Process.sleep(5)
    Circuits.GPIO.write(rst, 1)
    Process.sleep(50)
  end
end
