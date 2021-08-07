defmodule Translations.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Start a worker by calling: Translations.Worker.start_link(arg)
      # {Translations.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Translations.Supervisor)
  end
end
