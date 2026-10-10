# Everything that writes goes under tmp/test, which each test clears.
Application.put_env(:fairphone3_extras, :state_dir, Path.expand("../tmp/test/state", __DIR__))
# The modules log what they switch; keep test output to failures.
Logger.configure(level: :warning)
ExUnit.start()
