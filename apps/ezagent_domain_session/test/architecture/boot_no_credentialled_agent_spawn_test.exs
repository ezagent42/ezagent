defmodule EzagentDomainInstanceMessage.Architecture.BootNoCredentialledAgentSpawnTest do
  @moduledoc """
  Gate: **platform boot + seed start no credentialled agent, and the sole
  test-only exception stays `test_env?()`-gated.**

  ## The property this locks

  A fresh deploy / CI node boots with an EMPTY credential store (no host login
  `.credentials.json`, no user/workspace credential source). It must boot + seed
  green regardless, because no boot/seed path starts an agent that needs a login.
  The investigation
  `docs/notes/2026-07-10-session-agent-coupling-and-dev-cred-seed.md` §2 verified
  the property holds today:

    * boot starts exactly ONE agent, the **keyless** `py_default`
      (`provision_and_instantiate(PyAgentTemplate, …)` — a local-`uv` py agent,
      no credential adapter), boot-safe and self-healing;
    * every plugin `after_boot/0` otherwise only re-runs
      `Workspace.Loader.load_all/0` (revives PERSISTED workspace members — nothing
      on a clean DB) or seeds **config** (AgentTemplate Kinds + MCP bridge files),
      never a running credentialled agent;
    * the cc/codex orchestrator boot seeds write config only;
    * the one boot path that DOES spawn a credentialled agent (`main` session →
      cc orchestrator) is `maybe_seed_main_session_for_tests/0`, guarded by
      `if test_env?()` — a no-op in `:dev`/`:prod`.

  The dev-credential problem (a dev's local login credential is absent on
  commit/deploy/CI) is therefore a **first-USE** problem, not a boot problem —
  and NOTHING gated the boot property. This gate is that lock (spec §3, Q2
  recommendation (a): "highest leverage, cheap").

  ## Why a STATIC source scan, not a runtime boot test

  A runtime "boot the full supervision tree and enumerate started agents" test
  cannot cleanly assert this property. Under `MIX_ENV=test` — the only env a
  test runs in — the cc plugin's `after_boot/0` calls
  `maybe_seed_main_session_for_tests/0`, which creates `session://default/system/main`
  and thereby spawns a credentialled cc orchestrator. That agent is a TEST
  FIXTURE, not a production boot dependency; a runtime enumeration would find it
  and go red on behavior that is correct in prod. So — exactly as the sibling
  `session_create_no_agent_spawn_test.exs` chose for the create transaction — the
  contract gets a source-level scan of the boot/seed entry modules. It is blunt:
  any agent-spawn primitive appearing outside the allowlisted keyless / test-gated
  sites means a boot/seed path grew a credentialled agent.

  Companion runtime lock for the "seed SUCCEEDS with an empty credential store"
  half of the property (a source scan cannot catch a seed that merely READS a
  credential): `test/ezagent/socialware/seed_empty_credential_store_test.exs`.

  Sibling gate (same house style, create transaction):
  `session_create_no_agent_spawn_test.exs`.
  """
  use ExUnit.Case, async: true

  # Every boot/seed entry the platform runs at (or right after) startup. Each
  # plugin's `after_boot/0` is the agent-start seam; the seed modules must stay
  # config-only. Paths are relative to this app's root; `../` reaches sibling
  # umbrella apps (source is read from disk, same as the sibling gate).
  @scanned_modules [
    # --- plugin after_boot/0 hooks (the boot agent-start seam) ---
    "../ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex",
    "../ezagent_plugin_codex/lib/ezagent/plugin_codex/application.ex",
    "../ezagent_plugin_curl_agent/lib/ezagent_plugin_curl_agent/application.ex",
    "../ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex",
    "../ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/application.ex",
    "../ezagent_plugin_world/lib/ezagent_plugin_world/application.ex",
    "../ezagent_plugin_py/lib/ezagent_plugin_py/application.ex",
    # --- the domain-session boot app (owns the test-gated main seed) ---
    "lib/ezagent_domain_instance_message/application.ex",
    # --- boot seed modules (must be config-only) ---
    "../ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
    "../ezagent_plugin_codex/lib/ezagent/orchestrator/codex_orchestrator_seed.ex",
    "../ezagent_core/lib/ezagent/home/socialware_seed.ex",
    "lib/ezagent/socialware/manifest_seed.ex"
  ]

  # Agent-spawn / session-create primitives. Each STARTS an agent (or a session
  # whose install spawns one). At boot/seed, ANY of these — except the two
  # allowlisted sites below — would start a credentialled agent. We forbid the
  # spawn VERBS, deliberately not the flavor NOUNS: config-writing seeds
  # legitimately name flavors as DATA (`flavor: "cc"`, `CcAgent`), so a
  # noun-based scan false-positives on them; a verb-based scan does not.
  @forbidden [
    {"provision_and_instantiate", "provisions + starts an Agent Kind from a template"},
    {"create_session(",
     "creates a session whose install spawns its role agents (cc orchestrator)"},
    {"spawn_from_template_content", "spawns an Agent Kind from template content"},
    {"Domain.Pty", "starts a PTY subprocess (cc/codex credentialled flavor)"},
    {"DefinitionAgents", "spawns + joins + grants a socialware role agent"},
    {"materialize_definition_agents", "the agent-materialization transaction"},
    {"materialize_template_team", "config + agents; boot/seed may install config only"},
    {"RecipeMaterializer", "materializes an agent from a recipe"}
  ]

  # The ONLY two legitimate occurrences, allowlisted by their on-line signature:
  #
  #   * py `after_boot/0` provisions the KEYLESS `py_default` (a local-`uv` py
  #     agent with NO credential adapter) — the one agent boot may start.
  #   * `maybe_seed_main_session_for_tests/0` creates `main` (→ cc orchestrator)
  #     ONLY under `test_env?()`. The verb-scan allowlists it here; its teeth are
  #     the separate "is `test_env?()`-gated" assertion below — remove the guard
  #     and that test goes red even though this scan stays green.
  #   * the `default`-SessionTemplate fail-loud raise names `create_session(` in
  #     its error string (not a call) — allowlisted by its unique prose.
  @allowed_call_sites %{
    "../ezagent_plugin_py/lib/ezagent_plugin_py/application.ex" => [
      "Ezagent.Kind.Template.provision_and_instantiate("
    ],
    "lib/ezagent_domain_instance_message/application.ex" => [
      "Ezagent.Workspace.create_session(",
      "Every `create_session("
    ]
  }

  defp app_root, do: Path.expand("../..", __DIR__)

  defp source_lines(rel), do: app_root() |> Path.join(rel) |> File.read!() |> code_lines()

  # CODE lines only: `#` comments, blank lines and `@moduledoc`/`@doc` heredoc
  # BODIES are stripped, so the scan never trips on forensic prose (the docstrings
  # in these very modules NAME the primitives they avoid, e.g. cc's moduledoc
  # cites `Domain.Pty.start/2`).
  defp code_lines(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_doc} ->
      trimmed = String.trim(line)

      cond do
        in_doc and trimmed == ~s(""") -> {acc, false}
        in_doc -> {acc, true}
        doc_heredoc_open?(trimmed) -> {acc, true}
        trimmed == "" or String.starts_with?(trimmed, "#") -> {acc, false}
        true -> {[line | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.with_index(1)
  end

  defp doc_heredoc_open?(trimmed) do
    Enum.any?(~w(@moduledoc @doc @typedoc), &String.starts_with?(trimmed, &1 <> ~s( """)))
  end

  defp allowed?(rel, line) do
    @allowed_call_sites
    |> Map.get(rel, [])
    |> Enum.any?(&String.contains?(line, &1))
  end

  test "no boot/seed module starts an agent (except keyless py_default + the test-gated main seed)" do
    violations =
      for rel <- @scanned_modules,
          {line, lineno} <- source_lines(rel),
          not allowed?(rel, line),
          {needle, why} <- @forbidden,
          String.contains?(line, needle) do
        "#{rel}:#{lineno} — `#{needle}` (#{why})\n    #{String.trim(line)}"
      end

    assert violations == [],
           """
           A boot/seed path grew an agent-spawn primitive.

           Platform boot + the full seed path must SUCCEED with an EMPTY
           credential store and start NO credentialled agent. Boot may start only
           the KEYLESS `py_default`; boot seeds write CONFIG (AgentTemplates, MCP
           bridge files, socialware manifests), never a running credentialled
           agent. If a boot/seed path must run an agent, it belongs on the lazy
           first-use / session-install lane, not at startup.

           See `docs/notes/2026-07-10-session-agent-coupling-and-dev-cred-seed.md`
           §2. If this is a genuinely keyless boot agent, allowlist its exact
           call site in `@allowed_call_sites` with a justification.

           Violations:
           #{Enum.map_join(violations, "\n", &("  " <> &1))}
           """
  end

  # The teeth for the one live credentialled-boot-spawn site. `create_session(`
  # is allowlisted in the scan above; without THIS assertion the gate has a hole
  # exactly where it matters — someone deletes `if test_env?()` and ships a cc
  # orchestrator into prod boot while the verb scan stays green.
  test "maybe_seed_main_session_for_tests/0 (the one credentialled boot spawn) stays test_env?()-gated" do
    body =
      app_root()
      |> Path.join("lib/ezagent_domain_instance_message/application.ex")
      |> File.read!()

    [_, after_def] =
      String.split(body, "def maybe_seed_main_session_for_tests do", parts: 2)

    # The function body up to the next top-level `defp` (its private neighbour).
    [fn_body | _] = String.split(after_def, "\n  defp ", parts: 2)

    assert fn_body =~ "if test_env?()" or fn_body =~ "test_env?()",
           """
           `maybe_seed_main_session_for_tests/0` spawns a credentialled cc
           orchestrator (via `Ezagent.Workspace.create_session(... "main" ...)`).
           It MUST stay `test_env?()`-gated so the credentialled boot spawn is a
           no-op in `:dev`/`:prod`. The `if test_env?()` guard is gone — a fresh
           prod/CI deploy with an empty credential store would now try to start a
           credentialled orchestrator at boot.
           """

    assert String.contains?(fn_body, "Ezagent.Workspace.create_session("),
           "guard-assertion drifted: this test must scan the function that actually calls create_session/3"
  end
end
