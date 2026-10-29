defmodule Fp3Extras.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lawik/fp3_extras"

  def project do
    [
      app: :fp3_extras,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "The Fairphone 3's hardware from Elixir on Nerves: backlight and screen " <>
          "timeouts, volume, buttons, suspend and the way back from it, battery, the kernel console, " <>
          "orientation, ambient light from the camera, and the mics.",
      package: package(),
      docs: docs(),
      name: "Fp3Extras",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support.ex"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  # ex_audio is the one hardware library depended on: it routes the sound
  # card at boot and Volume and Mic set mixer controls through it. The
  # others (input_event, circuits_gpio, ex_qcom_smgr, fp3_camera) are
  # called only when loaded, so the project compiles and tests on a
  # laptop, and a firmware adds the libraries for the modules it uses.
  # See the README.
  defp deps do
    [
      {:ex_audio, github: "mlainez/ex_audio"},
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
        Display: [
          Fp3Extras.Backlight,
          Fp3Extras.Panel,
          Fp3Extras.Screen,
          Fp3Extras.Console
        ],
        Sound: [Fp3Extras.Volume, Fp3Extras.Mic],
        Signals: [Fp3Extras.Leds, Fp3Extras.Vibrator],
        Input: [Fp3Extras.Buttons, Fp3Extras.Orientation],
        Power: [
          Fp3Extras.Sleep,
          Fp3Extras.Power,
          Fp3Extras.WiFi,
          Fp3Extras.WiFi.PowerManager,
          Fp3Extras.WiFi.Watchdog,
          Fp3Extras.Battery
        ],
        Sensing: [Fp3Extras.LightSensor, Fp3Extras.LightSensor.Source],
        Experiments: [Fp3Extras.Fingerprint, Fp3Extras.TEE.QSEECom]
      ]
    ]
  end
end
