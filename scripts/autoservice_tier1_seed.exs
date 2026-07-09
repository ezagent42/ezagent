# AutoService Tier-1 seed — the wiring scenario-13 (S1→S4) needs to be runnable.
#
# scenario-13 (docs/e2e/scenario-13-autoservice-end-to-end.md, #1044) honest
# finding / open-question #2: there is NO seed today wiring "a tool-loop agent +
# an ingested kb-agent + a default always→agent route + public_view" into one
# runnable chain. THIS module is that seed.
#
# It is a PURE MODULE (no top-level side effects) so it can be loaded by BOTH:
#   * the live in-node serve-seed (scripts/autoservice_tier1_serve_seed.exs),
#     which keeps the public_view session LIVE in the serving BEAM (the
#     ezagent-socialware local-e2e-recipe §2 trap), and
#   * the deterministic regression test
#     (apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs),
#     which `Code.require_file`s this file so the test exercises the EXACT seed
#     wiring, not a parallel hand-built one (advisor #4).
#
# What it wires (Tier-1 chain):
#   (a) a `kb` × native kb-agent with a FIXED corpus carrying a fact that is
#       ONLY in the corpus (ZEPHYR-7731) — the soul-assertion anchor;
#   (b) an AutoService agent (cc-flavor orchestrator on the live path; any
#       tool-loop-capable flavor in test) that holds the `kb.query` cap so it
#       can retrieve from (a) via the orchestrator MCP tool;
#   (c) a public_view session;
#   (d) a session-scoped `always → AutoService-agent` routing rule so the
#       customer's BARE message (no @handle) reaches the agent (scenario-04
#       found new sessions route nothing without an @mention).
#
# Two distinct soul claims (do NOT conflate — advisor #2):
#   * RETRIEVAL soul (deterministic, proven by the test): `kb.query` against the
#     seeded kb-agent returns the ZEPHYR-7731 fact + an audited `query` granted
#     invocation. Flavor-independent.
#   * ANSWER soul (needs the live cc tool-loop): a CHAT REPLY weaving the fact
#     in, produced by a live `claude` orchestrator. Reported as the remaining
#     GAP — it rides cc's known PTY/startup blockers (scenario-05 / GAP-4).

defmodule Ezagent.AutoService.Tier1Seed do
  @moduledoc "See file header. Idempotent, composable Tier-1 seed steps."

  require Logger

  alias Ezagent.{Capability, Invocation, Workspace}
  alias Ezagent.URI, as: EzUri
  alias Ezagent.Routing.{Matcher, RuleStore}

  # The corpus fact that excludes the model prior: an invented support access
  # code. A correct S3 answer MUST contain this token, which no LLM could know
  # without retrieving the seeded corpus. The token is the SOUL ANCHOR the test
  # asserts on; the corpus TEXT that carries it is now DEFINITION DATA in the
  # AutoService socialware package (priv/socialware_seed/autoservice/kb), not code.
  @kb_fact_token "ZEPHYR-7731"
  @kb_probe_query "support hotline access code"

  @doc "The fact token a correct S3 answer must contain (soul anchor)."
  def kb_fact_token, do: @kb_fact_token

  @doc "A query whose FTS5 MATCH retrieves the corpus chunk holding the fact."
  def kb_probe_query, do: @kb_probe_query

  @typedoc "Seed result — every URI the runbook / test needs."
  @type result :: %{
          workspace_uri: URI.t(),
          kb_agent_uri: URI.t(),
          kb_agent_name: String.t(),
          autoservice_agent_uri: URI.t(),
          autoservice_agent_status: :created | {:blocked, term()},
          session_uri: URI.t(),
          rule_id: integer() | nil,
          orchestrator_caps: MapSet.t()
        }

  @doc """
  Run the whole Tier-1 seed. Idempotent. `opts`:

    * `:ws`                  — workspace name (default `"autosvc"`)
    * `:kb_agent`            — kb-agent name (default `"kb-tier1"`)
    * `:autoservice_agent`   — AutoService agent name (default `"autoservice"`)
    * `:autoservice_flavor`  — flavor for the AutoService agent (default `"cc"`;
                               the test passes a generic tool flavor)
    * `:session`             — session short name (default `"tier1"`)
    * `:admin_ctx`           — caller+caps map for privileged create calls
                               (default: genesis admin)
    * `:register_recipes`    — register kb recipe + flavor (default `false`;
                               the live node already registered them at boot —
                               the test passes `true`)
  """
  @spec seed(keyword()) :: {:ok, result()} | {:error, term()}
  def seed(opts \\ []) do
    ws = Keyword.get(opts, :ws, "autosvc")
    kb_agent = Keyword.get(opts, :kb_agent, "kb-tier1")
    autosvc_agent = Keyword.get(opts, :autoservice_agent, "autoservice")
    autosvc_flavor = Keyword.get(opts, :autoservice_flavor, "cc")
    # AutoService agent role: "orchestrator" on the live node threads the
    # orchestrator MCP bridge so a live claude exposes kb_query. The test passes
    # a minimal role it registers itself (the orchestrator role recipe is a
    # session/cc-boot concern, not present in the isolated kb test).
    autosvc_role = Keyword.get(opts, :autoservice_role, "orchestrator")
    # cc flavor REQUIRES a non-empty cwd (the agent's project working dir) —
    # create returns {:error, :cwd_required_for_cc} otherwise. Default to a
    # per-agent dir under the ezagent home. Non-cc test flavors ignore cwd.
    autosvc_cwd =
      Keyword.get(opts, :autoservice_cwd, default_autoservice_cwd(ws, autosvc_agent))

    # kb-agent flavor: `native` on the live node (kb = role `kb` × flavor
    # `native`, per EzagentPluginKb.Application). The test passes its own
    # registered flavor.
    kb_flavor = Keyword.get(opts, :kb_flavor, "native")
    session_short = Keyword.get(opts, :session, "tier1")
    admin_ctx = Keyword.get(opts, :admin_ctx, admin_ctx())

    workspace_uri = EzUri.new!("workspace://#{ws}")
    # The AutoService agent URI is DETERMINISTIC — computed up front so the
    # public_view session + the always→agent routing rule can be wired
    # regardless of whether the cc-orchestrator agent itself is creatable
    # (the live cc create path is blocked — see ensure_autoservice_agent).
    autosvc_uri = EzUri.agent(ws, autosvc_agent)

    # Order matters: kb-agent + corpus + public_view session + routing rule
    # come FIRST so S1 (anon landing) / S2a (route) / S3 (retrieval) / S4
    # (operator sees the session) are live-runnable. The AutoService AGENT is
    # created LAST and BEST-EFFORT: a cc-flavor orchestrator is NOT a
    # `create_agent` role (`{:role_unsupported_for_flavor, "cc"}`) — it is
    # materialized via the session-create orchestrator-template path. So a cc
    # failure is REPORTED as `autoservice_agent_status`, not a silent degrade,
    # and does not block the rest of the chain.
    with :ok <- maybe_register_recipes(opts, autosvc_flavor, kb_flavor, autosvc_role),
         :ok <- ensure_workspace(ws),
         {:ok, kb_uri} <- ensure_kb_agent(workspace_uri, ws, kb_agent, kb_flavor, admin_ctx),
         {:ok, _chunks} <- ingest_corpus(kb_uri, ws, admin_ctx),
         {:ok, session_uri} <- ensure_public_view_session(ws, session_short),
         {:ok, rule_id} <- ensure_always_to_agent_rule(session_uri, autosvc_uri) do
      autosvc_status =
        wire_autoservice_agent(
          workspace_uri,
          ws,
          autosvc_agent,
          autosvc_flavor,
          autosvc_role,
          autosvc_cwd,
          session_uri,
          kb_agent,
          admin_ctx
        )

      {:ok,
       %{
         workspace_uri: workspace_uri,
         kb_agent_uri: kb_uri,
         kb_agent_name: kb_agent,
         autoservice_agent_uri: autosvc_uri,
         autoservice_agent_status: autosvc_status,
         session_uri: session_uri,
         rule_id: rule_id,
         orchestrator_caps: orchestrator_kb_caps()
       }}
    end
  end

  # Best-effort: create the AutoService agent, and (if created) grant it
  # kb.query + join it to the session. Returns `:created` or
  # `{:blocked, reason}` — the cc-orchestrator live create path is blocked
  # (`{:role_unsupported_for_flavor, "cc"}`); the deterministic chain (kb +
  # route + public_view) is already wired before this runs.
  defp wire_autoservice_agent(
         workspace_uri,
         ws,
         name,
         flavor,
         role,
         cwd,
         session_uri,
         kb_agent,
         admin_ctx
       ) do
    case ensure_autoservice_agent(workspace_uri, ws, name, flavor, role, cwd, kb_agent, admin_ctx) do
      {:ok, autosvc_uri} ->
        with :ok <-
               maybe_bind_session_orchestrator(session_uri, autosvc_uri, flavor, role),
             :ok <-
               maybe_register_orchestrator(
                 autosvc_uri,
                 session_uri,
                 workspace_uri,
                 flavor,
                 role,
                 admin_ctx
               ),
             :ok <-
               maybe_ensure_session_manager(
                 autosvc_uri,
                 session_uri,
                 workspace_uri,
                 flavor,
                 role,
                 admin_ctx
               ),
             :ok <- grant_orchestrator_kb_query(autosvc_uri, workspace_uri, admin_ctx),
             :ok <- join_member(session_uri, autosvc_uri, :agent) do
          :created
        else
          {:error, reason} -> {:blocked, reason}
        end

      {:error, reason} ->
        Logger.warning(
          "autosvc-seed: AutoService AGENT not created (#{inspect(reason)}) — the " <>
            "kb + route + public_view chain is wired; a cc-flavor orchestrator must be " <>
            "materialized via the session-create orchestrator-template path."
        )

        {:blocked, reason}
    end
  end

  # ── steps ──────────────────────────────────────────────────────────────

  @doc "Genesis-admin ctx for privileged create/ingest dispatches."
  def admin_ctx do
    %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: MapSet.new([Capability.admin_genesis_cap()])
    }
  end

  @doc """
  The caps the AutoService orchestrator carries to call `kb.query` (kb-retrieval
  SPEC §5.3 option 1 — orchestrator authority). The kind axis is `:agent`: the
  kb behavior mounts on the generic `Entity.Agent` host; a `:kb`-kind cap would
  be rejected (kb.ex moduledoc). Query-only here — the orchestrator never
  ingests at runtime.
  """
  def orchestrator_kb_caps do
    MapSet.new([Capability.cap(:agent, Ezagent.ActionSet.Kb, :query)])
  end

  # The kb recipe + kb flavor + AutoService flavor. On the live node these are
  # registered at boot, so this is opt-in (`:register_recipes`).
  defp maybe_register_recipes(opts, autosvc_flavor, kb_flavor, autosvc_role) do
    if Keyword.get(opts, :register_recipes, false) do
      register_recipes(autosvc_flavor, kb_flavor, autosvc_role)
    else
      :ok
    end
  end

  @doc """
  Register the kb role recipe + the kb/AutoService flavors + a minimal
  AutoService role recipe (idempotent). Only needed when the seed runs OUTSIDE a
  fully-booted node (the test); the live node registered all of these at boot.

  The minimal AutoService role recipe REQUESTS the `kb.query` cap so the created
  AutoService agent genuinely holds it via CapMint (advisor: the cap must be
  seeded, not hand-built). On the live node the orchestrator's kb authority
  comes from the session/orchestrator caps machinery (kb-retrieval SPEC §5.3
  option 1) instead.
  """
  def register_recipes(autosvc_flavor, kb_flavor, autosvc_role) do
    reg = Ezagent.AgentFlavorRegistry

    # kb resource types (kb-store / kb-source) for FsResolver — mirror the
    # kb_role_native_test setup.
    _ =
      Ezagent.Resource.FsResolver.Registry.register_all(
        EzagentPluginKb.Application.resource_types()
      )

    _ = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(EzagentPluginKb.Application.kb_recipe())

    # Minimal AutoService role — requests the kb.query cap so the agent holds it.
    # Only registered for a NON-"orchestrator" role (the real orchestrator recipe
    # is owned by session/cc boot; don't shadow it).
    if autosvc_role != "orchestrator" do
      _ =
        Ezagent.Agent.RecipeRegistry.seed_role_if_absent(%{
          name: autosvc_role,
          passive: false,
          behaviors: [],
          requested_caps: [%{behavior: Ezagent.ActionSet.Kb, action: :query}]
        })
    end

    # Permissive cap policies (test only): every requested cap granted, mirroring
    # the kb test's cap_policy/1 — fail-closed CapMint is exercised elsewhere
    # (kb_role_native_test §8.3); here we are wiring the chain, not re-testing it.
    grant_all = fn _requested -> fn _needed -> true end end

    for flavor <- Enum.uniq([kb_flavor, autosvc_flavor]) do
      _ =
        reg.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: nil,
          cap_policy: grant_all
        })
    end

    :ok
  end

  defp ensure_workspace(ws) do
    case Workspace.create(ws, %{}) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, :already_exists} ->
        :ok

      # Workspace.create may report an existing ws in several shapes; treat a
      # live/persisted workspace as success.
      other ->
        if workspace_live_or_persisted?(ws) do
          :ok
        else
          {:error, {:workspace_create_failed, other}}
        end
    end
  end

  defp workspace_live_or_persisted?(ws) do
    uri = EzUri.new!("workspace://#{ws}")

    match?({:ok, _}, Ezagent.KindRegistry.lookup(uri)) or
      not is_nil(Ezagent.Workspace.Store.get_by_name(ws))
  rescue
    _ -> false
  end

  defp ensure_kb_agent(workspace_uri, ws, name, kb_flavor, admin_ctx) do
    uri = EzUri.agent(ws, name)

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        {:ok, uri}

      :error ->
        case Workspace.create_agent(
               workspace_uri,
               %{flavor: kb_flavor, name: name, role: "kb", cwd: "", with_pty: false},
               admin_ctx
             ) do
          {:ok, %{agent_uri: ^uri}} -> {:ok, uri}
          {:ok, %{agent_uri: other}} -> {:ok, other}
          {:error, reason} -> {:error, {:kb_agent_create_failed, reason}}
        end
    end
  end

  # ── package data (definition-data boundary) ─────────────────────────────
  # The AutoService socialware app's DEFINITION DATA (support persona + KB
  # corpus) lives as package files under `priv/socialware_seed/autoservice/`,
  # not hardcoded in this installer. This seed is the installer/harness that
  # reads them (docs/together/contributing/socialware-data-deployment-boundary.md).
  # Deploy-seed SPEC §6: the package now ships in the ezagent_web assembly app
  # (the deploy-seed source of truth), not domain_session priv.
  @package_app :ezagent_web
  @package_rel "priv/socialware_seed/autoservice"

  defp package_dir, do: Application.app_dir(@package_app, @package_rel)

  defp kb_corpus, do: File.read!(Path.join(package_dir(), "kb/tier1-corpus.md"))

  defp ingest_corpus(kb_uri, ws, admin_ctx) do
    source_name = "tier1-corpus"
    dir = Path.join([Ezagent.Home.path("kb-sources"), ws])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, source_name), kb_corpus())
    source_uri = "resource://#{ws}/kb-source/#{source_name}"

    cmd =
      Ezagent.Cmd.new(
        EzUri.with_action(kb_uri, :kb, :ingest),
        :ingest,
        %{source_uri: source_uri},
        %{
          mode: :call,
          caller: admin_ctx.caller,
          caps: admin_ctx.caps,
          reply: {:caller_inbox, self()}
        }
      )

    case Ezagent.Router.dispatch(cmd) do
      {:ok, %{chunks: n}} ->
        Logger.info("autosvc-seed: ingested #{n} chunk(s) into #{URI.to_string(kb_uri)}")
        {:ok, n}

      {:error, reason} ->
        {:error, {:kb_ingest_failed, reason}}

      other ->
        {:error, {:kb_ingest_unexpected, other}}
    end
  end

  defp default_autoservice_cwd(ws, name) do
    Path.join([Ezagent.Home.path("agents"), ws, name])
  rescue
    _ -> Path.join([System.tmp_dir!(), "autosvc-agents", ws, name])
  end

  defp ensure_autoservice_agent(workspace_uri, ws, name, flavor, role, cwd, kb_agent, admin_ctx) do
    uri = EzUri.agent(ws, name)

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        {:ok, uri}

      :error ->
        do_ensure_autoservice_agent(
          uri,
          workspace_uri,
          ws,
          name,
          flavor,
          role,
          cwd,
          kb_agent,
          admin_ctx
        )
    end
  end

  defp do_ensure_autoservice_agent(
         uri,
         workspace_uri,
         _ws,
         _name,
         "cc",
         "orchestrator",
         cwd,
         kb_agent,
         admin_ctx
       ) do
    # RF-5b is intentionally not supported by the generic Workspace.create_agent
    # route for file flavors (`{:role_unsupported_for_flavor, "cc"}`). The
    # session-create path materializes cc orchestrators by reading the seeded
    # cc-orchestrator AgentTemplate and invoking Agent.spawn_from_template_content.
    # Mirror that path here while keeping the deterministic autoservice URI.
    source_template_uri = Ezagent.URI.template(:system, :agent, "cc-orchestrator")
    _ = if cwd != "", do: File.mkdir_p(cwd)

    # Support-agent persona: the cc-orchestrator template primes a TEAM-manager
    # persona, so without this the agent has no support context and deflects/flails
    # instead of using kb_query. Written to the cwd CLAUDE.md (claude project
    # memory) BEFORE the PTY launches. (Verified 2026-06-30 in the T1 return.)
    _ = write_support_persona(cwd, kb_agent)

    with {:ok, content} <-
           Ezagent.Orchestrator.Tools.read_source_template_content(source_template_uri),
         content <- autoservice_orchestrator_template_content(content, cwd),
         {:ok, _result} <-
           Ezagent.Entity.Agent.spawn_from_template_content(
             content,
             uri,
             admin_ctx.caller,
             workspace_uri,
             caller: admin_ctx.caller,
             caps: admin_ctx.caps,
             source_template_uri: source_template_uri
           ) do
      {:ok, uri}
    else
      {:error, reason} -> {:error, {:autoservice_agent_create_failed, reason}}
    end
  end

  defp do_ensure_autoservice_agent(
         _uri,
         workspace_uri,
         _ws,
         name,
         flavor,
         role,
         cwd,
         _kb_agent,
         admin_ctx
       ) do
    # Non-cc test/native flavors still use the generic create path exercised by
    # the deterministic seed test.
    _ = if cwd != "", do: File.mkdir_p(cwd)

    case Workspace.create_agent(
           workspace_uri,
           %{flavor: flavor, name: name, role: role, cwd: cwd, with_pty: false},
           admin_ctx
         ) do
      {:ok, %{agent_uri: got}} -> {:ok, got}
      {:error, reason} -> {:error, {:autoservice_agent_create_failed, reason}}
    end
  end

  defp autoservice_orchestrator_template_content(content, cwd) do
    content
    |> Map.put(:project_cwd, cwd)
    |> Map.put("project_cwd", cwd)
    |> Map.put(:role, "orchestrator")
    |> Map.put("role", "orchestrator")
  end

  # Bind the session → orchestrator (the canonical `Materializer.store_session_
  # orchestrator_uri/2` the real session-create flow uses). This is the SOURCE OF
  # TRUTH: `Orchestrator.McpServer.resolve_session/1` reverse-resolves the session
  # from the orchestrator URI by scanning sessions for a chat-slice
  # `working_copy.orchestrator_uri` that matches. Without it the orchestrator MCP's
  # `kb_query` (and the auto-`McpRegistry.register` in `build_context`) fail with a
  # "session context error". Setting it both fixes the kb_query context AND drives
  # the MCP server's own registration. Accepts the deterministic autoservice URI.
  defp maybe_bind_session_orchestrator(session_uri, autosvc_uri, "cc", "orchestrator") do
    # `McpServer.orchestrator_working_copy/1` GATES on `:orchestrator_template_uri`
    # being a `%URI{}` and only THEN returns the wc carrying `:orchestrator_uri`.
    # So the session→orchestrator binding needs BOTH keys, written into the chat
    # slice's `template_working_copy` (the same primitives the real flow's
    # `Materializer.{materialize_orchestrator_working_copy,store_session_orchestrator_uri}`
    # use). read-modify-write preserves the `session_template_uri` already set by
    # `ensure_public_view_session`.
    orch_template_uri = Ezagent.URI.template(:system, :agent, "cc-orchestrator")

    working_copy =
      session_uri
      |> Ezagent.Entity.Session.read_template_working_copy()
      |> Map.put(:orchestrator_template_uri, orch_template_uri)
      |> Map.put(:orchestrator_uri, autosvc_uri)

    case Ezagent.ActionSet.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} ->
        Logger.info("autosvc-seed: bound session→orchestrator #{URI.to_string(autosvc_uri)}")
        :ok

      {:error, reason} ->
        {:error, {:bind_session_orchestrator_failed, reason}}

      other ->
        {:error, {:bind_session_orchestrator_failed, other}}
    end
  rescue
    e -> {:error, {:bind_session_orchestrator_failed, e}}
  end

  defp maybe_bind_session_orchestrator(_session, _uri, _flavor, _role), do: :ok

  # Register the AutoService agent as an orchestrator so its `esr-orchestrator`
  # MCP-channel join is accepted. `Ezagent.Orchestrator.McpChannel` gates
  # fail-closed on a `McpRegistry` row; without it every orchestrator tool (incl.
  # `kb_query`) fails with `:orchestrator_not_registered`. The real session-create
  # orchestrator flow writes this row — the seed materializes the agent directly
  # via `spawn_from_template_content`, so it must register here. ETS-backed →
  # re-registered every boot (the live seed re-runs at boot). Only meaningful for
  # the live cc orchestrator; non-cc test flavors are not orchestrators.
  defp maybe_register_orchestrator(
         autosvc_uri,
         session_uri,
         workspace_uri,
         "cc",
         "orchestrator",
         admin_ctx
       ) do
    case Ezagent.Orchestrator.McpRegistry.register(autosvc_uri,
           session_uri: session_uri,
           workspace_uri: workspace_uri,
           owner_uri: admin_ctx.caller
         ) do
      :ok ->
        Logger.info("autosvc-seed: registered orchestrator #{URI.to_string(autosvc_uri)}")
        :ok

      {:error, reason} ->
        {:error, {:register_orchestrator_failed, reason}}
    end
  rescue
    e -> {:error, {:register_orchestrator_failed, e}}
  end

  defp maybe_register_orchestrator(_uri, _session, _ws, _flavor, _role, _ctx), do: :ok

  # Start the orchestrator's `SessionManager` (the per-orchestrator-session executor
  # the orchestrator MCP `tools/call` path needs — `McpServer` returns
  # `:orchestrator_context_unavailable` without a live one). This is the missing
  # piece that left `kb_query` silently failing even after B/C/D: the bridge token
  # was minted at cc spawn (`McpConfigWriter.write_with_token!`), but no SessionManager
  # was reconstructing the orchestrator's session-side caps. Modeled on the sanctioned
  # `agent_contract_g4` setup (`SessionManager.ensure_started/1`, all public API).
  # Idempotent (`ensure_started`); only for the live cc orchestrator.
  defp maybe_ensure_session_manager(
         autosvc_uri,
         session_uri,
         workspace_uri,
         "cc",
         "orchestrator",
         admin_ctx
       ) do
    case Ezagent.Session.SessionManager.ensure_started(
           orchestrator_uri: autosvc_uri,
           session_uri: session_uri,
           workspace_uri: workspace_uri,
           owner_uri: admin_ctx.caller
         ) do
      {:ok, _sm} ->
        Logger.info("autosvc-seed: started SessionManager for #{URI.to_string(autosvc_uri)}")
        :ok

      {:error, reason} ->
        {:error, {:ensure_session_manager_failed, reason}}
    end
  rescue
    e -> {:error, {:ensure_session_manager_failed, e}}
  end

  defp maybe_ensure_session_manager(_uri, _session, _ws, _flavor, _role, _ctx), do: :ok

  # Write a tier-1 support-agent persona into the agent's cwd `CLAUDE.md` (claude
  # project memory). The AutoService agent reuses the cc-orchestrator (team-manager)
  # template to obtain the orchestrator MCP (the `kb_query` tool), so without a
  # support persona it has no support context and deflects/flails instead of
  # querying the kb. Best-effort (never blocks create).
  defp write_support_persona(cwd, kb_agent) when is_binary(cwd) and cwd != "" do
    File.write(Path.join(cwd, "CLAUDE.md"), support_persona(kb_agent))
  end

  defp write_support_persona(_cwd, _kb_agent), do: :ok

  # The support persona is DEFINITION DATA (a package file), templated with the
  # kb-agent name at install time. `{{kb_agent}}` is the only placeholder.
  defp support_persona(kb_agent) do
    package_dir()
    |> Path.join("persona/support-agent.md")
    |> File.read!()
    |> String.replace("{{kb_agent}}", kb_agent)
  end

  # Grant the AutoService orchestrator the `kb.query` cap INTO ITS OWN identity
  # slice — the exact source the live orchestrator reads
  # (`SessionManager.load_orchestrator_caps/1` = `Identity.read_entity_caps/1`,
  # which reconstructs the orchestrator's delegated caps session-side). Without
  # this grant, a seeded cc-orchestrator's delegated caps are the orchestration
  # tools only; `kb.query` would DENY at the dispatch chokepoint (fail-closed) —
  # the live-S3 cap gap. Granted by admin; query-only (the orchestrator never
  # ingests at runtime). Idempotent (grant_cap upserts the cap).
  @doc false
  def grant_orchestrator_kb_query(autosvc_uri, workspace_uri, admin_ctx) do
    cap = Capability.cap(:agent, Ezagent.ActionSet.Kb, :query, :any, workspace_uri)

    case Ezagent.Identity.grant_cap(autosvc_uri, cap, admin_ctx.caller) do
      :ok ->
        Logger.info("autosvc-seed: granted kb.query to #{URI.to_string(autosvc_uri)}")
        :ok

      {:error, reason} ->
        {:error, {:grant_kb_query_failed, reason}}
    end
  end

  # Create a LIVE anonymous-web-access session in the current BEAM (recipe §2: the
  # public controller gates on the live session slice before join, so the
  # session must be live in the serving node). Idempotent.
  defp ensure_public_view_session(ws, short) do
    session_uri = EzUri.new!("session://#{ws}/default/#{short}")
    definition_name = "autosvc-#{short}"

    {:ok, _} =
      Ezagent.Socialware.DefinitionRegistry.seed_definition_if_absent(
        %{
          name: definition_name,
          bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
          shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
          visibility_policy: %{publish_policy: :auto, web_anon_access: true}
        },
        workspace_uri: Ezagent.URI.workspace(ws)
      )

    content = %{name: "autosvc-#{short}", installs: [definition_name]}

    {:ok, tmpl} =
      Ezagent.Entity.SessionTemplate.persist_version_as_system(content, ws)

    {:ok, behaviors} =
      Ezagent.Socialware.Installation.behavior_set_for_template(
        content,
        Ezagent.URI.workspace(ws)
      )

    case Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
           uri: session_uri,
           behaviors: behaviors
         }) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    :ok =
      Ezagent.Socialware.Installation.install_template_installs(
        session_uri,
        Ezagent.URI.workspace(ws),
        content,
        Ezagent.Entity.User.admin_uri()
      )

    {:ok, _} =
      Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(session_uri, %{
        session_template_uri: tmpl
      })

    {:ok, session_uri}
  rescue
    e -> {:error, {:public_view_session_failed, e}}
  end

  # Join `member_uri` to the session as `class` (:agent | :user). Mirrors
  # world_e2e_seed: create a read-only member row carrying its own join+send
  # grants, spawn the principal, self-join, mount participation caps.
  @doc false
  def join_member(session_uri, member_uri, class) do
    ws = Capability.workspace_of(session_uri)

    cap = fn action ->
      %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.Session,
        action: action,
        instance: session_uri,
        workspace_uri: ws,
        granted_by: member_uri,
        granted_at: DateTime.utc_now()
      }
    end

    join_cap = cap.(:join)
    send_cap = cap.(:send)

    _ = Ezagent.Users.create_read_only(member_uri, [join_cap, send_cap])
    _ = Ezagent.Entity.spawn_principal(member_uri)

    _ =
      Invocation.dispatch(%Invocation{
        target: EzUri.with_action(session_uri, :session, :join),
        mode: :call,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: MapSet.new([join_cap]), reply: :ignore}
      })

    _ = Ezagent.ActionSet.Session.Membership.mount_participation_caps(session_uri, member_uri)
    Logger.info("autosvc-seed: joined #{class} #{URI.to_string(member_uri)}")
    :ok
  rescue
    e -> {:error, {:join_failed, e}}
  end

  # S2a: a session-scoped `always → AutoService-agent` rule so the customer's
  # BARE message (no @mention) routes to the agent. `{:in_session, s}` IS
  # "always within this session"; receiver is the concrete agent URI. Idempotent
  # — skips if an identical rule already exists.
  @doc false
  def ensure_always_to_agent_rule(session_uri, agent_uri) do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
    session_str = URI.to_string(session_uri)
    agent_str = URI.to_string(agent_uri)
    matcher = Matcher.in_session(session_str)

    existing =
      RuleStore.list(table)
      |> Enum.find(fn r ->
        r.matcher_data == Matcher.to_json(matcher) and agent_str in r.receivers
      end)

    if existing do
      _ = RuleStore.load_into_registry(table)
      {:ok, existing.id}
    else
      case RuleStore.add(table, matcher, [agent_str], nil, source: "autoservice_tier1") do
        {:ok, row} ->
          :ok = RuleStore.load_into_registry(table)
          Logger.info("autosvc-seed: routing rule always(in_session)→#{agent_str} id=#{row.id}")
          {:ok, row.id}

        {:error, reason} ->
          {:error, {:routing_rule_failed, reason}}
      end
    end
  end

  @doc """
  Customer (anon) deep-link for the public_view chat surface, and the operator
  console deep-link. Mirrors the scenario-13 runbook entry URLs.
  """
  def deep_links(%{session_uri: session_uri}, base \\ "http://localhost:10042") do
    enc = session_uri |> URI.to_string() |> URI.encode_www_form()
    operator_base = operator_base_url(base)

    %{
      customer: "#{base}/socialware/chat?session_uri=#{enc}",
      operator: "#{operator_base}/sessions?session=#{enc}"
    }
  end

  defp operator_base_url(base) do
    case System.get_env("EZAGENT_OPERATOR_BASE_URL") do
      nil -> default_operator_base_url(base)
      "" -> default_operator_base_url(base)
      override -> String.trim_trailing(override, "/")
    end
  end

  defp default_operator_base_url(base) do
    uri = URI.parse(base)

    case uri.host do
      host when host in ["localhost", "127.0.0.1"] ->
        uri
        |> Map.put(:host, "world.localhost")
        |> URI.to_string()
        |> String.trim_trailing("/")

      _other ->
        String.trim_trailing(base, "/")
    end
  end
end
