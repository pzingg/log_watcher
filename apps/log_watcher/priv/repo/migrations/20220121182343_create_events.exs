defmodule LogWatcher.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table("events", primary_key: false) do
      add :id, :bigserial, autogenerate: true
      add :version, :integer, null: false, default: 1
      add :topic, :string, null: false
      add :type, :string
      add :source, :string
      add :data, :map
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nothing)
      add :transaction_id, :string
      add :ttl, :integer
      add :initialized_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, inserted_at: false, updated_at: :occurred_at)
    end

    create index(:events, [:topic])
    create index(:events, [:type])
    create index(:events, [:source])
    create index(:events, [:session_id])
    create index(:events, [:transaction_id])
  end
end
