defmodule LogWatcher.Repo do
  use Ecto.Repo,
    otp_app: :log_watcher,
    adapter: Ecto.Adapters.Postgres
end
