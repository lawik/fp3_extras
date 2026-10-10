defmodule Fp3Extras.Fingerprint do
  @moduledoc """
  Experiment: the rear fingerprint sensor as a touch button. A dead end.

  The Elan sensor sits on SPI7 (GPIO 135-138), which TrustZone owns: the
  device tree reserves the pins and touching them from Linux faults.
  Android's driver never touches SPI either; all I/O happens in a QSEE
  app through qseecom. Linux owns three sideband lines:

    * GPIO 90 - VDD enable (low at boot)
    * GPIO 140 - reset, active low
    * GPIO 48 - interrupt, rising edge on Android

  `watch/0` powers the sensor, pulses reset like the Android driver and
  logs edges on GPIO 48. Result: GPIO 48 reads low with any pull, powered
  or not, and never moves on touch or reset. The chip raises no interrupt
  without SPI setup only the TrustZone app can do. Kept as a harness, and
  because GPIO 90 is a power lever. The way forward is
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
