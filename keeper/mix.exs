defmodule Keeper.MixProject do
  use Mix.Project

  def project do
    [
      app: :keeper,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Keeper.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"}
    ]
  end

  defp releases do
    [
      keeper: [
        strip_beams: true
      ]
    ]
  end
end
