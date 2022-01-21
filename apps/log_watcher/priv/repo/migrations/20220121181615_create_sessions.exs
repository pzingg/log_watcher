defmodule LogWatcher.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, null: false, primary_key: true
      add :name, :string, null: false
      add :description, :string, null: false
      add :tag, :string, null: false
      add :log_path, :string, null: false
      add :gen, :integer
      add :acked_event_id, :integer
      add :user_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps()
    end

    create index(:sessions, [:user_id])
    create index(:sessions, [:name])
    create index(:sessions, [:tag], unique: true)
  end
end
