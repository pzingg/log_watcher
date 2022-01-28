ExUnit.start()
Faker.start()

Ecto.Adapters.SQL.Sandbox.mode(LogWatcher.Repo, :manual)

# See https://hexdocs.pm/broadway/Broadway.html#module-testing-with-ecto
# If running :async (not recommended):
# BroadwayEctoSandbox.attach(LogWatcher.Repo)
