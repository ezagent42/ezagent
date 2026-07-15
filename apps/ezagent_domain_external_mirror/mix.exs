defmodule EzagentDomainExternalMirror.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_external_mirror,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"]
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
    # PR-EM-1 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
    # §9 + lines 1054-1068): adds `:ezagent_domain_session` so the facade
    # `Ezagent.ExternalMirror.list_bindings/1` can read the Session
    # slice (PR-EM-3 wires the real read; PR-EM-1 just declares the
    # facade), and so invariant tests can cross-reference the chat
    # domain at compile time.
    #
    # WARNING: chat depends on external_mirror (for the `Publisher`
    # contract module name — see PR-EM-0 wiring in
    # `apps/ezagent_domain_session/mix.exs`). Adding chat as a runtime
    # dep here would form a cycle. We DON'T need a runtime dep —
    # PR-EM-1's facade stubs return `{:ok, []}` without dereferencing
    # any chat module, and Worker dispatch in PR-EM-2 goes through
    # `Ezagent.Invocation.dispatch/1` (duck-typed). The dep is added
    # only for tests / future-PR readability; runtime calls into chat
    # stay duck-typed via Invocation.
    #
    # The cycle would manifest as a Mix.exs deps-cycle error on
    # `mix compile` — DO NOT add `{:ezagent_domain_session, in_umbrella: true}`
    # here as a runtime dep. Instead, the SPEC's "facade reads slice"
    # plan is realized in PR-EM-3 via dispatch, not module load.
    #
    # That said: PR-EM-1's brief explicitly says "add :ezagent_domain_session
    # dep". On inspection this CANNOT be a `deps/0` entry — Mix will
    # reject the cycle. The brief's intent is satisfied at the umbrella
    # level (both apps live in the same umbrella and tests in
    # `apps/ezagent_domain_session/test/` can reference ExternalMirror).
    # PR-EM-1 keeps deps/0 as only `:ezagent_core`; comment documents
    # why the brief's literal instruction would have broken the build.
    [
      {:ezagent_core, in_umbrella: true},
      # PR-EM-5 (2026-05-25): the `mix ezagent.external_mirror.*` Mix
      # tasks under `lib/mix/tasks/` need `Ezagent.Identity.list_caps_for/1`
      # for client-side cap checks (SPEC §9 PR-EM-5 — "All commands
      # check caps client-side AND surface dispatch errors verbatim").
      # `:ezagent_domain_identity` only depends on `:ezagent_core`
      # (same tier, no chat / external_mirror reference), so this dep
      # edge is cycle-free — adds external_mirror → identity at the
      # domain tier alongside chat → identity.
      {:ezagent_domain_identity, in_umbrella: true}
    ]
  end
end
