defmodule Fp3Extras do
  @moduledoc """
  The Fairphone 3's hardware from Elixir on Nerves: small modules, one
  thing each, with no knowledge of the application around them.

  Modules that keep state across reboots write under `state_dir/0`:

      config :fp3_extras, state_dir: "/data/phone"

  The default is `/data/fp3_extras`.

  Only `ex_audio` is a hard dependency. The rest are called when loaded:
  `Fp3Extras.Buttons` needs `input_event`, `Fp3Extras.Orientation`
  `ex_qcom_smgr`, `Fp3Extras.LightSensor` `fp3_camera`,
  `Fp3Extras.Fingerprint` `circuits_gpio`, `Fp3Extras.Sleep` and
  `Fp3Extras.WiFi` `vintage_net`.
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
