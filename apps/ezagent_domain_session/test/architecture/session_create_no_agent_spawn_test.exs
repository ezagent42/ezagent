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

  test "create_session/3 reachable call graph contains no Agent spawn writer" do
    source =
      app_root()
      |> Path.join("lib/ezagent_domain_instance_message/session_creator.ex")
      |> File.read!()

    assert reachable_agent_spawn_calls(source, {:create_session, 3}) == []
  end

  test "create-session gate detects an actual Agent spawn hidden behind an innocuous helper" do
    source = """
    defmodule GateFixture do
      def create_session(name, owner, opts), do: persist(name, owner, opts)
      defp persist(_name, _owner, _opts), do: write_record()
      defp write_record, do: Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{})
    end
    """

    assert [
             %{function: {:write_record, 0}, writer: "Ezagent.Kind.spawn(Ezagent.Entity.Agent)"}
           ] = reachable_agent_spawn_calls(source, {:create_session, 3})
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

  # ── R4: extend the gate to the INSTALL lane ────────────────────────────────
  #
  # The create gate above proves create spawns no agent. The install lane
  # (`install_session_socialware/1`, run in a fire-and-forget supervised Task) is
  # where agents ARE spawned — but it must obey the OTHER half of the #912
  # contract: **a role member that fails to start never rolls the session back**.
  # An install failure is LOUD (Logger.error + `…:socialware_install:failed`
  # telemetry) and leaves the session alive + owner-only — never a rollback, never
  # a hang. This static gate locks the "never rollback" half.
  #
  # NOTE (Phase 3 split): S6 removes the recipe-cap readiness coupling and the
  # gate below locks that lane to binding/create or issue/absorb. The
  # orchestrator-scoped grant remains a separate S7 cutover; this S6 gate must
  # not erase that stage boundary by scanning unrelated orchestrator hooks.
  test "the install lane never rolls back the session (R4 — loud, not rollback)" do
    body =
      app_root()
      |> Path.join("lib/ezagent_domain_instance_message/session_creator.ex")
      |> File.read!()

    [_, from_install] =
      String.split(
        body,
        ~s|def install_session_socialware(%URI{scheme: "session"} = session_uri) do|,
        parts: 2
      )

    # Everything from the install entry up to the next unrelated public helper is
    # the install lane (both `install_session_socialware/1,2`,
    # `do_install_session_socialware/3`, `install_session_socialware_async/1`, and
    # `run_install_loudly/1`). `rollback_session` first appears far below, on the
    # CREATE path (`verify_or_recreate` / the finalize failure branch).
    [install_lane | _] = String.split(from_install, "def demand_spawn_member(", parts: 2)

    refute install_lane =~ "rollback_session",
           """
           The post-create install lane calls `rollback_session`.

           #912 contract: a declared role member that fails to start must NOT roll
           the session back. `install_session_socialware/1` runs AFTER the
           owner-only session is durable; its failure is LOUD (Logger.error +
           `[:ezagent, :session, :socialware_install, :failed]` telemetry) and
           leaves the session alive + usable — never a rollback.
           """
  end

  test "install-lane recipe caps never block on an issuer-driven grant to the fresh agent" do
    definition_agents =
      app_root()
      |> Path.join("lib/ezagent_domain_instance_message/session_creator/definition_agents.ex")
      |> File.read!()

    [_, materialize] = String.split(definition_agents, "defp materialize_fresh_agent(", parts: 2)
    [materialize | _] = String.split(materialize, "defp spawn_bound_agent(", parts: 2)

    refute materialize =~ "grant_recipe_caps",
           "fresh role materialization must end after binding + spawn/join; recipe caps self-store in create/1"

    refute definition_agents =~ "GrantRecipeCaps.grant_recipe_caps",
           "the install lane must not drive a cap-write into the freshly materialized grantee"

    grant_recipe_caps =
      Path.expand(
        "../ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex",
        app_root()
      )
      |> File.read!()

    refute grant_recipe_caps =~ "Ezagent.Identity.grant_cap("
    refute grant_recipe_caps =~ "Ezagent.Identity.Grant.grant_cap("
    assert grant_recipe_caps =~ "Ezagent.Cap.issue("
    assert grant_recipe_caps =~ "Ezagent.Identity.absorb_cap("
    assert grant_recipe_caps =~ "Map.has_key?(instance_overrides, behavior)"
  end

  # ── R2 + R3: orchestrator post-materialize ordering ────────────────────────
  #
  # `maybe_after_materialize/5` runs three steps for the orchestrator slot. Their
  # order is load-bearing:
  #   1. VERIFY the durable pre-stored `:orchestrator_uri` binding matches the
  #      ACTUAL spawned URI and obtain its epoch (R2/P1);
  #   2. REGISTER the MCP context — the tool-surface registration must precede the
  #      grant, not follow it (R3, the pre-fix order was grant-then-register);
  #   3. GRANT the scope-bounded caps LAST.
  # The store + register both target already-ready Kinds (the Session / the MCP
  # registry), so they never block on the not-yet-ready agent.
  test "orchestrator post-materialize order is verify binding → register → grant (R2/R3/P1)" do
    body =
      app_root()
      |> Path.join("lib/ezagent_domain_instance_message/session_creator/definition_agents.ex")
      |> File.read!()

    [_, after_head] =
      String.split(body, "defp maybe_after_materialize(", parts: 2)

    [fn_body | _] = String.split(after_head, "defp orchestrator_recipe_slot?(", parts: 2)

    verify_at = index_of(fn_body, "ensure_orchestrator_binding(session_uri, agent_uri)")
    register_at = index_of(fn_body, "register_orchestrator_mcp_context(")
    grant_at = index_of(fn_body, "grant_orchestrator_scoped_caps(")

    assert verify_at != nil, "binding verification call not found in maybe_after_materialize/5"
    assert register_at != nil, "register_orchestrator_mcp_context call not found"
    assert grant_at != nil, "grant_orchestrator_scoped_caps call not found"

    assert verify_at < register_at and register_at < grant_at,
           """
           maybe_after_materialize/5 must run: VERIFY pre-stored binding (R2/P1) →
           REGISTER mcp context (R3) → GRANT scoped caps. Got byte offsets
           verify=#{verify_at}, register=#{register_at}, grant=#{grant_at}.
           """
  end

  test "existing-orchestrator repair registers context and executor before granting authority" do
    source =
      app_root()
      |> Path.join("lib/ezagent/entity/session/orchestrator.ex")
      |> File.read!()

    [_, compat_tail] = String.split(source, "defp ensure_orchestrator_compat(", parts: 2)

    [compat_body | _] =
      String.split(compat_tail, "defp adopt_legacy_orchestrator_member(", parts: 2)

    register_at = index_of(compat_body, "register_orchestrator_mcp_context(")
    grant_at = index_of(compat_body, "grant_orchestrator_scoped_caps(")

    assert register_at != nil, "repair path must register the orchestrator context"
    assert grant_at != nil, "repair path must grant the orchestrator scoped caps"

    assert register_at < grant_at,
           "existing-member repair must establish context + executor before " <>
             "exposing scoped authority"

    [_, register_tail] =
      String.split(source, "def register_orchestrator_mcp_context(", parts: 2)

    [register_body | _] =
      String.split(register_tail, "@doc \"Ensure the SessionTemplate Kind", parts: 2)

    context_at = index_of(register_body, "OrchestratorContextPort.register_context(")
    executor_at = index_of(register_body, "SessionManager.ensure_started(")

    assert context_at != nil, "context registration call not found"
    assert executor_at != nil, "SessionManager executor start call not found"

    assert context_at < executor_at,
           "context must be registered before the session-owned executor is exposed"
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {start, _len} -> start
      :nomatch -> nil
    end
  end

  defp reachable_agent_spawn_calls(source, entrypoint) do
    ast =
      Code.string_to_quoted!(source,
        warn_on_unnecessary_quotes: false,
        emit_warnings: false
      )

    definitions =
      Macro.prewalk(ast, %{}, fn
        {kind, _meta, [head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          case function_signature(head) do
            nil -> {node, acc}
            signature -> {node, Map.update(acc, signature, [body], &[body | &1])}
          end

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    definitions
    |> reachable_definitions([entrypoint], MapSet.new())
    |> Enum.flat_map(fn signature ->
      definitions
      |> Map.fetch!(signature)
      |> Enum.flat_map(&spawn_writers(&1, signature))
    end)
  end

  defp reachable_definitions(_definitions, [], visited), do: MapSet.to_list(visited)

  defp reachable_definitions(definitions, [signature | rest], visited) do
    cond do
      MapSet.member?(visited, signature) ->
        reachable_definitions(definitions, rest, visited)

      not Map.has_key?(definitions, signature) ->
        reachable_definitions(definitions, rest, visited)

      true ->
        callees =
          definitions
          |> Map.fetch!(signature)
          |> Enum.flat_map(&local_calls/1)
          |> Enum.filter(&Map.has_key?(definitions, &1))

        reachable_definitions(
          definitions,
          callees ++ rest,
          MapSet.put(visited, signature)
        )
    end
  end

  defp local_calls(body) do
    Macro.prewalk(body, MapSet.new(), fn
      {{:., _, _}, _, _} = node, calls ->
        {node, calls}

      {name, _, args} = node, calls when is_atom(name) and is_list(args) ->
        {node, MapSet.put(calls, {name, length(args)})}

      node, calls ->
        {node, calls}
    end)
    |> elem(1)
    |> MapSet.to_list()
  end

  defp spawn_writers(body, signature) do
    Macro.prewalk(body, [], fn node, calls ->
      case spawn_writer(node) do
        nil -> {node, calls}
        writer -> {node, [%{function: signature, writer: writer} | calls]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp spawn_writer(
         {{:., _, [{:__aliases__, _, kind_module}, :spawn]}, _,
          [
            {:__aliases__, _, agent_module} | _args
          ]}
       )
       when kind_module in [[:Ezagent, :Kind], [:Kind]] and
              agent_module in [[:Ezagent, :Entity, :Agent], [:Entity, :Agent], [:Agent]],
       do: "Ezagent.Kind.spawn(Ezagent.Entity.Agent)"

  defp spawn_writer({{:., _, [{:__aliases__, _, module}, function]}, _, _args})
       when {module, function} in [
              {[:Ezagent, :SpawnRegistry], :spawn},
              {[:Ezagent, :SpawnRegistry], :spawn_detailed},
              {[:SpawnRegistry], :spawn},
              {[:SpawnRegistry], :spawn_detailed},
              {[:Ezagent, :Agent, :RecipeMaterializer], :create_agent_from_recipe},
              {[:RecipeMaterializer], :create_agent_from_recipe}
            ],
       do: "#{Enum.join(module, ".")}.#{function}"

  defp spawn_writer({{:., _, [_module, :spawn_from_template_content]}, _, _args}),
    do: "spawn_from_template_content"

  defp spawn_writer(_node), do: nil

  defp function_signature({:when, _, [head | _guards]}), do: function_signature(head)
  defp function_signature({name, _, nil}) when is_atom(name), do: {name, 0}

  defp function_signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp function_signature(_head), do: nil

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
