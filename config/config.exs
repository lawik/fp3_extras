import Config

# ex_audio depends on ex_remoteproc, whose boot task kicks the ADSP. On a
# laptop there's none to kick; this stops it trying (and logging) in tests.
if config_env() == :test do
  config :ex_remoteproc, start: []
  config :fp3_extras, state_dir: Path.expand("../tmp/test/state", __DIR__)
end
