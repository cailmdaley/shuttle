defmodule Shuttle.MixProject do
  use Mix.Project

  def project do
    [
      app: :shuttle,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Shuttle.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [
      main_module: Shuttle.CLI,
      name: "shuttle",
      path: "bin/shuttle"
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
