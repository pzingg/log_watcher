# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     LogWatcher.Repo.insert!(%LogWatcher.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

user1 =
  %LogWatcher.Accounts.User{
    first_name: "Peter",
    last_name: "Zingg",
    email: "bezos@amazon.com"
  }
  |> LogWatcher.Repo.insert!()

tag = LogWatcher.Sessions.Session.generate_tag()

log_dir =
  Path.join([
    :code.priv_dir(:log_watcher),
    "mock_command",
    "sessions",
    tag,
    "output"
  ])

_session1 =
  %LogWatcher.Sessions.Session{
    user: user1,
    name: "First session",
    description: "Trial session",
    tag: tag,
    log_dir: log_dir,
    gen: 0
  }
  |> LogWatcher.Repo.insert!()
