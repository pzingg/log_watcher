defmodule LogWatcher.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table("events", primary_key: false) do
      add :id, :bigserial, autogenerate: true
      add :version, :integer, null: false, default: 1
      add :type, :string
      add :source, :string
      add :data, :map
      add :command_id, :string
      add :ttl, :integer
      add :initialized_at, :utc_datetime, null: false
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime, inserted_at: :occurred_at, updated_at: false)
    end

    create index(:events, [:type])
    create index(:events, [:source])
    create index(:events, [:session_id])
    create index(:events, [:command_id])
  end
end
