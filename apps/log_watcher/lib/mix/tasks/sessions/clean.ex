defmodule Mix.Tasks.Sessions.Clean do
  @moduledoc "Removes stale dev sessions from priv"
  use Mix.Task

  @shortdoc "Removes stale dev sessions from priv"
  def run(_) do
    case File.ls(LogWatcher.session_base_dir()) do
      {:ok, files} ->
        removed =
          Enum.reduce(files, 0, fn file, count ->
            if Enum.member?([".", ".."], file) do
              count
            else
              case File.rm_rf(Path.join(LogWatcher.session_base_dir(), file)) do
                {:ok, _} -> count + 1
                _ -> count
              end
            end
          end)

        if removed == 1 do
          IO.puts("1 session directory removed")
        else
          IO.puts("#{removed} session directories removed")
        end

        :ok

      _ ->
        :ok
    end
  end
end
