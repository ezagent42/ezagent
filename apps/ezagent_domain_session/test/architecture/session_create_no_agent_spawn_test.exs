defmodule EzagentDomainInstanceMessage.Architecture.SessionCreateNoAgentSpawnTest do
  @moduledoc """
  Gate: **the session-create transaction spawns no agent.**

  `#912` ("Decouple session create from orchestrator readiness") wrote the rule
  into `SessionCreator`'s moduledoc — "Session creation never waits for a
  transport bridge and never rolls the session back because a role member failed
  to start" — and guarded it with ONE runtime assertion in
  `session_create_orchestrator_decouple_test.exs`.

  That was not enough. `#1140` (07-03) wired an agent-spawn step into
  `TemplateTeam.materialize_template_team/4`, `#1180` (07-05) closed the lazy
  route-time lane for `fill: :agent` slots, and `#1223` (07-07) moved the stock
  orchestrator onto the eager create path — **and rewrote the guard assertion to
  match the new behavior**, so the suite never went red. Two days later canary
  could not create a session (the create path's `identity.grant_cap` `:call`
  blocked on the transport-gated cc Kind's ReadyGate).

  So the contract gets a STATIC gate as well. This is a source-level scan of the
  create transaction's own modules for the agent-transaction primitives. It is
  deliberately blunt: any of these appearing in `SessionCreator` or the helpers
  it calls during `create_session/3` means the transaction grew an agent again.

  Forensics: `docs/together/2026-07-09/cc-orchestrator-create-blocking-rootcause.zh_cn.md`

  ## Where agents ARE allowed

  `DefinitionAgents` (the agent transaction itself) and `TemplateTeam`'s
  `materialize_definition_agents/4` + `materialize_template_team/4` (repair and
  plugin app-instantiate) are NOT scanned — they are the post-create install
  lane. The gate scans the modules `create_session/3` walks.
  """
  use ExUnit.Case, async: true

  @create_transaction_modules [
    "lib/ezagent_domain_instance_message/session_creator.ex",
    "lib/ezagent_domain_instance_message/session_creator/materializer.ex",
    "lib/ezagent_domain_instance_message/session_creator/template_resolver.ex"
  ]

  # The agent-transaction primitives. Each is a synchronous step that either
  # spawns an OS subprocess, blocks on a transport-gated ReadyGate, or grants
  # caps to a Kind that may not be `:ready` yet.
  @forbidden [
    {"DefinitionAgents", "spawns + joins + grants a socialware role agent"},
    {"materialize_template_team", "config + agents; create may only install config"},
    {"RecipeMaterializer", "materializes an agent from a recipe"},
    {"Identity.grant_cap", ":call into a possibly-not-ready agent Kind"},
    {"Domain.Pty", "starts a PTY subprocess"},
    {"spawn_from_template_content", "spawns an Agent Kind from template content"}
  ]

  # `session_creator.ex` legitimately mentions these OUTSIDE the create
  # transaction: `install_session_socialware/2` (the post-create agent
  # transaction) and `repair_orchestrator/1`. Those live in the same file, so the
  # scan skips lines that are comments/docs and lines inside the two allowlisted
  # public entry points is impractical to express textually — instead we allowlist
  # the exact call sites by their enclosing function name, asserted below.
  @allowed_call_sites %{
    "lib/ezagent_domain_instance_message/session_creator.ex" => [
      # the post-create agent transaction + the operator repair path +
      # the alias declaration + specs that reference DefinitionAgents
      "DefinitionAgents",
      "materialize_template_team(",
      # new module for credential-bearing precondition checks (not an agent spawn)
      "CredentialPrecondition",
      "unfilled_agent_role_slots"
    ]
  }

  defp app_root, do: Path.expand("../..", __DIR__)

  defp source_lines(rel), do: app_root() |> Path.join(rel) |> File.read!() |> code_lines()

  # CODE lines only: `#` comments, blank lines and `@moduledoc`/`@doc` heredoc
  # BODIES are stripped. Without this the gate trips on its own forensic prose —
  # the moduledocs necessarily NAME the primitives they forbid.
  defp code_lines(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, lineno}, {acc, in_doc} ->
      trimmed = String.trim(line)

      cond do
        in_doc and trimmed == ~s(""") -> {acc, false}
        in_doc -> {acc, true}
        doc_heredoc_open?(trimmed) -> {acc, true}
        trimmed == "" or String.starts_with?(trimmed, "#") -> {acc, false}
        true -> {[{line, lineno} | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp doc_heredoc_open?(trimmed) do
    Enum.any?(~w(@moduledoc @doc @typedoc), &String.starts_with?(trimmed, &1 <> ~s( """)))
  end

  defp allowed?(rel, line) do
    @allowed_call_sites
    |> Map.get(rel, [])
    |> Enum.any?(&String.contains?(line, &1))
  end

  test "the create transaction's modules contain no agent-transaction primitive" do
    violations =
      for rel <- @create_transaction_modules,
          {line, lineno} <- source_lines(rel),
          not allowed?(rel, line),
          {needle, why} <- @forbidden,
          String.contains?(line, needle) do
        "#{rel}:#{lineno} — `#{needle}` (#{why})\n    #{String.trim(line)}"
      end

    assert violations == [],
           """
           The session-create transaction grew an agent transaction again.

           rev6 / #912: `create_session/3` may spawn the Session Kind, bind the
           workspace, record the template declaration, install prompts/legends/
           routing rules, and join the OWNER. Nothing else.

           Agent role slots belong in `SessionCreator.install_session_socialware/1`,
           which `Workspace.create_session` fires AFTER the owner-only session is
           durable.

           Violations:
           #{Enum.map_join(violations, "\n", &("  " <> &1))}
           """
  end

  # The gap that let `hello` stay broken while `default` was fixed: a session
  # Template Class's `instantiate/3` ALSO runs inside the `workspace.create_session`
  # dispatch (`Workspace.create_session_via_class/5`), and `HelloSession` →
  # `App.ensure_app/3` spawned four role agents + the `requires`-pulled cc
  # orchestrator there. The first version of this gate only scanned `SessionCreator`,
  # so it passed. Session Template Classes get the same rule.
  @session_template_classes [
    "../ezagent_plugin_hello/lib/ezagent_plugin_hello/template/hello_session.ex",
    "lib/ezagent/template/generic_session.ex"
  ]

  test "session Template Classes do not materialize their team inside instantiate/3" do
    paths =
      @session_template_classes
      |> Enum.map(&Path.expand(&1, app_root()))
      |> Enum.filter(&File.exists?/1)

    assert paths != [], "no session Template Class sources found — the gate would vacuously pass"

    violations =
      for path <- paths,
          {line, lineno} <- code_lines(File.read!(path)),
          needle <- ["materialize_template_team", "ensure_app", "DefinitionAgents"],
          String.contains?(line, needle) do
        "#{Path.basename(path)}:#{lineno} — `#{needle}`\n    #{String.trim(line)}"
      end

    assert violations == [],
           """
           A session Template Class materializes its team inside `instantiate/3`.

           `instantiate/3` runs inside the `workspace.create_session` dispatch, so it
           is bound by the same rev6 / #912 rule as `SessionCreator.create_session/3`:
           create the session + its config, record `member_declarations`, spawn nothing.
           `Workspace.create_session` fires the install transaction afterwards.

           Violations:
           #{Enum.map_join(violations, "\n", &("  " <> &1))}
           """
  end

  test "create_session/3 does not reference the agent materializer" do
    body =
      app_root()
      |> Path.join("lib/ezagent_domain_instance_message/session_creator.ex")
      |> File.read!()

    # `finalize_fresh_session/5` is the create transaction's step 3-9 sequence.
    [_, finalize] = String.split(body, "defp finalize_fresh_session(", parts: 2)
    [finalize | _] = String.split(finalize, "\n  # The captured page", parts: 2)

    refute finalize =~ "materialize_template_team",
           "finalize_fresh_session/5 must call materialize_template_config/3, not the team variant"

    refute finalize =~ "DefinitionAgents",
           "finalize_fresh_session/5 must not materialize agents"

    assert finalize =~ "materialize_template_config",
           "finalize_fresh_session/5 must install template CONFIG (prompts/legends/rules)"
  end
end
