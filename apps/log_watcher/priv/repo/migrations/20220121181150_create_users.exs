defmodule LogWatcher.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, null: false, primary_key: true
      add :first_name, :string, null: false
      add :last_name, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
