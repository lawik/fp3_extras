defmodule Fairphone3Extras.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lawik/fairphone3_extras"

  def project do
    [
      app: :fairphone3_extras,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "The Fairphone 3's hardware from Elixir on Nerves: backlight and screen " <>
          "timeouts, volume, buttons, suspend, battery, the kernel console, " <>
          "orientation, ambient light from the camera, and the mics.",
      package: package(),
      docs: docs(),
      name: "Fairphone3Extras",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support.ex"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  # Nothing here is a hard dependency. Each module calls the library it
  # needs (input_event, circuits_gpio, ex_qcom_smgr, fp3_camera) only when
  # it's loaded, so the project compiles and tests on a laptop, and a
  # firmware adds the libraries for the modules it uses. See the README.
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv guides mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/hardware.md",
        "guides/display.md",
        "guides/suspend.md",
        "guides/audio.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Display: [Fairphone3Extras.Backlight, Fairphone3Extras.Screen, Fairphone3Extras.Console],
        Sound: [Fairphone3Extras.Volume, Fairphone3Extras.Mic],
        Input: [Fairphone3Extras.Buttons, Fairphone3Extras.Orientation],
        Power: [Fairphone3Extras.Power, Fairphone3Extras.Battery],
        Sensing: [Fairphone3Extras.LightSensor, Fairphone3Extras.LightSensor.Source],
        Experiments: [Fairphone3Extras.Fingerprint, Fairphone3Extras.TEE.QSEECom]
      ]
    ]
  end
end
