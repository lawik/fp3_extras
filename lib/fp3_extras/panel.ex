defmodule Fp3Extras.Panel do
  @moduledoc """
  The panel and display pipeline, through fbdev's `blank`.

  The msm DRM driver emulates a framebuffer at `/dev/fb0`, and its
  `/sys/class/graphics/fb0/blank` reaches the DRM driver's DPMS: writing
  `4` (`FB_BLANK_POWERDOWN`) asks it to switch the display pipeline off
  and put the panel to sleep, `0` wakes it. That's a different lever from
  the backlight: `Fp3Extras.Backlight.power/1` only turns the light off,
  which saves about 20 mW, while the panel's DSI link, the display
  controller and the panel itself stay powered.

  This is how mlainez's `hello_watch` darkens the TicWatch Pro 3 on the
  same kind of Qualcomm display stack: the app blanks
  `/sys/class/graphics/fb0/blank`, and its system notes say that powers
  the panel down with the DSI panel driver.

  On the Fairphone 3 the write itself was timed on 2026-10-10 (the
  suspend guide has the numbers), but only with nothing holding the
  display. An application that drives the display through DRM is the DRM
  master while it does, and the fb helper defers to the master: blanking
  then does nothing. So the application may have to stop its DRM client,
  or have it release the display, before the pipeline actually powers
  down. This module has not been tried in that sequence as of
  2026-10-10; measure with `Fp3Extras.Battery.measure/2` when you do.

  Suspend to idle (`Fp3Extras.Power`) takes the display down regardless,
  so blanking matters only while the phone stays awake with the screen
  dark.

  Without the file (a laptop) both functions return `:ok` and do nothing.
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
