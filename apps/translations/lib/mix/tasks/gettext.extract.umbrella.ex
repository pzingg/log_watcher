defmodule Mix.Commands.Gettext.Extract.Umbrella do
  use Mix.Task
  @recursive false

  def run(args) do
    unless Mix.Project.umbrella?() do
      msg =
        "Cannot run task gettext.extract.umbrella from place " <>
          "other than umbrella application root dir."

      Mix.raise(msg)
    end

    _ = Application.ensure_all_started(:gettext)
    force_recompile_and_extract()

    Mix.Task.run("gettext.extract", args)
  end

  defp force_recompile_and_extract do
    Gettext.Extractor.enable()
    Mix.Task.run("compile", ["--force"])
  after
    Gettext.Extractor.disable()
  end
end
