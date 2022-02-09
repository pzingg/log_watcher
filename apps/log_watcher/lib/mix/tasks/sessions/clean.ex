defmodule Mix.Tasks.Sessions.Clean do
  @moduledoc "Removes stale dev sessions from priv"
  use Mix.Task

  def rm_rf(files, dir) do
    Enum.reduce(files, 0, fn file, count ->
      if Enum.member?([".", ".."], file) do
        count
      else
        case File.rm_rf(Path.join(dir, file)) do
          {:ok, _} -> count + 1
          _ -> count
        end
      end
    end)
  end

  @shortdoc "Removes stale dev sessions from priv"
  def run(_) do
    dir = LogWatcher.session_base_dir()

    case File.ls(dir) do
      {:ok, files} ->
        case rm_rf(files, dir) do
          1 ->
            IO.puts("1 session directory removed")

          count ->
            IO.puts("#{count} session directories removed")
        end

        :ok

      {:error, reason} ->
        IO.puts("Could not list directory #{dir}: #{reason}")
        :ok
    end
  end
end
