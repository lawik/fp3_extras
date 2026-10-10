defmodule Fp3Extras do
  @moduledoc """
  The Fairphone 3's hardware from Elixir on Nerves, in small modules that
  each do one thing and know nothing about the application around them.

  Everything was first written for a phone UI and then lifted out; what's
  here is the part that touches sysfs, ALSA, evdev and the phone's
  sensors. The UI-shaped parts (state containers, rendering, settings
  pages) stayed behind. See the guides for what was learned about the
  hardware along the way.

  ## Where files go

  Modules that keep something across reboots (the volume, the screen's
  settings, the mic routing) write under `state_dir/0`:

      config :fp3_extras, state_dir: "/data/phone"

  The default is `/data/fp3_extras`. On a laptop set it to a
  directory in the project.

  ## Hardware libraries

  Apart from `ex_audio`, nothing here is a hard dependency. A module that
  needs one of these calls it only when it's loaded, so add to the
  firmware what the modules you start need:

    * `Fp3Extras.Buttons` - `input_event`
    * `Fp3Extras.Orientation` - `ex_qcom_smgr`
    * `Fp3Extras.LightSensor` - `fp3_camera`
    * `Fp3Extras.Fingerprint` - `circuits_gpio`

  `Fp3Extras.Volume` and `Fp3Extras.Mic` set mixer controls through
  `ex_audio`, the one hardware library this one depends on.
  """

  @doc "Where the modules keep their files (`config :fp3_extras, :state_dir`)."
  @spec state_dir() :: Path.t()
  def state_dir,
    do: Application.get_env(:fp3_extras, :state_dir, "/data/fp3_extras")

  @doc false
  # Reads a sysfs attribute as a trimmed string.
  def sysfs_read(path) do
    with {:ok, text} <- File.read(path), do: {:ok, String.trim(text)}
  end

  @doc false
  # Reads a sysfs attribute as an integer.
  def sysfs_int(path) do
    with {:ok, text} <- sysfs_read(path),
         {value, _} <- Integer.parse(text) do
      {:ok, value}
    else
      {:error, _} = error -> error
      :error -> {:error, :not_an_integer}
    end
  end
end
