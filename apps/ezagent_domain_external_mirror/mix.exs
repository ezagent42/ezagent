defmodule EzagentDomainExternalMirror.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_external_mirror,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentDomainExternalMirror.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    # PR-EM-0 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
    # §9): only `:ezagent_core` for the Publisher behaviour contract +
    # cap-Behavior. `:ezagent_domain_chat` dep arrives in PR-EM-1 when
    # the AdapterRegistry/BindingRegistry/Worker Kind layers land —
    # PR-EM-0 deliberately keeps the Publisher contract free of a
    # runtime dep on the publishing domain (Session IS the implementer
    # and lives in `domain.chat`, but lookup is duck-typed via
    # `Invocation.dispatch` against the publisher URI).
    [
      {:ezagent_core, in_umbrella: true}
    ]
  end
end
