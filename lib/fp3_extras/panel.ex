defmodule Fp3Extras.Panel do
  @moduledoc """
  Powers the panel and display pipeline down through fbdev's `blank`.

  The msm DRM driver emulates `/dev/fb0`, and
  `/sys/class/graphics/fb0/blank` reaches its DPMS: `4` powers the
  pipeline and panel down (about 340 mW), `0` brings them back.
  `Fp3Extras.Backlight.power/1` only turns the light off (about 20 mW).

  The fb helper defers to a DRM master, so the write does nothing while an
  application drives the display through DRM: stop the client, then
  blank; unblank, then restart it. This module is untested in that
  sequence. Suspend to idle takes the display down regardless, so this
  only matters awake with the screen dark.

  Without the file both functions return `:ok`.
  """

  @blank "/sys/class/graphics/fb0/blank"

  @doc "Powers the panel down (`true`) or back up (`false`)."
  @spec blank(boolean(), Path.t()) :: :ok | {:error, term()}
  def blank(down?, path \\ @blank) when is_boolean(down?) do
    if File.exists?(path), do: File.write(path, if(down?, do: "4", else: "0")), else: :ok
  end

  @doc "Whether the panel is blanked, or `{:error, :enoent}` without fbdev."
  @spec blanked?(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def blanked?(path \\ @blank) do
    with {:ok, value} <- Fp3Extras.sysfs_int(path), do: {:ok, value != 0}
  end
end
