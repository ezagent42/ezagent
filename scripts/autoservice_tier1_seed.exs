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
  # without retrieving the seeded corpus.
  @kb_fact_token "ZEPHYR-7731"
  @kb_corpus """
  AutoService Tier-1 internal knowledge base.

  Emergency escalation procedure for tier-one customers:
  The support hotline access code for tier-one customers is #{@kb_fact_token}.
  Agents MUST quote this access code verbatim when a customer asks how to reach
  the priority support hotline. The code rotates quarterly and is published only
  in this knowledge base, never to the model.
  """
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
    # kb-agent flavor: `native` on the live node (kb = role `kb` × flavor
    # `native`, per EzagentPluginKb.Application). The test passes its own
    # registered flavor.
    kb_flavor = Keyword.get(opts, :kb_flavor, "native")
    session_short = Keyword.get(opts, :session, "tier1")
    admin_ctx = Keyword.get(opts, :admin_ctx, admin_ctx())

    workspace_uri = EzUri.new!("workspace://#{ws}")

    with :ok <- maybe_register_recipes(opts, autosvc_flavor, kb_flavor, autosvc_role),
         :ok <- ensure_workspace(ws),
         {:ok, kb_uri} <- ensure_kb_agent(workspace_uri, ws, kb_agent, kb_flavor, admin_ctx),
         {:ok, _chunks} <- ingest_corpus(kb_uri, ws, admin_ctx),
         {:ok, autosvc_uri} <-
           ensure_autoservice_agent(
             workspace_uri,
             ws,
             autosvc_agent,
             autosvc_flavor,
             autosvc_role,
             admin_ctx
           ),
         :ok <- grant_orchestrator_kb_query(autosvc_uri, workspace_uri, admin_ctx),
         {:ok, session_uri} <- ensure_public_view_session(ws, session_short),
         :ok <- join_member(session_uri, autosvc_uri, :agent),
         {:ok, rule_id} <- ensure_always_to_agent_rule(session_uri, autosvc_uri) do
      caps = orchestrator_kb_caps()

      {:ok,
       %{
         workspace_uri: workspace_uri,
         kb_agent_uri: kb_uri,
         kb_agent_name: kb_agent,
         autoservice_agent_uri: autosvc_uri,
         session_uri: session_uri,
         rule_id: rule_id,
         orchestrator_caps: caps
       }}
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
    MapSet.new([Capability.cap(:agent, Ezagent.Behavior.Kb, :query)])
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

    _ = Ezagent.RoleRegistry.register(EzagentPluginKb.Application.kb_recipe())

    # Minimal AutoService role — requests the kb.query cap so the agent holds it.
    # Only registered for a NON-"orchestrator" role (the real orchestrator recipe
    # is owned by session/cc boot; don't shadow it).
    if autosvc_role != "orchestrator" do
      _ =
        Ezagent.RoleRegistry.register(%{
          name: autosvc_role,
          passive: false,
          behaviors: [],
          requested_caps: [%{behavior: Ezagent.Behavior.Kb, action: :query}]
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
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_exists} -> :ok
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

  defp ingest_corpus(kb_uri, ws, admin_ctx) do
    source_name = "tier1-corpus"
    dir = Path.join([Ezagent.Home.path("kb-sources"), ws])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, source_name), @kb_corpus)
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

  defp ensure_autoservice_agent(workspace_uri, ws, name, flavor, role, admin_ctx) do
    uri = EzUri.agent(ws, name)

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        {:ok, uri}

      :error ->
        # role "orchestrator" threads the orchestrator MCP bridge (cc flavor) so
        # a live claude exposes the 7-tool surface incl. kb_query.
        case Workspace.create_agent(
               workspace_uri,
               %{flavor: flavor, name: name, role: role, cwd: "", with_pty: false},
               admin_ctx
             ) do
          {:ok, %{agent_uri: got}} -> {:ok, got}
          {:error, reason} -> {:error, {:autoservice_agent_create_failed, reason}}
        end
    end
  end

  # Grant the AutoService orchestrator the `kb.query` cap INTO ITS OWN identity
  # slice — the exact source the live orchestrator reads
  # (`SessionManager.load_orchestrator_caps/1` = `Identity.list_caps_for/1`,
  # which reconstructs the orchestrator's delegated caps session-side). Without
  # this grant, a seeded cc-orchestrator's delegated caps are the orchestration
  # tools only; `kb.query` would DENY at the dispatch chokepoint (fail-closed) —
  # the live-S3 cap gap. Granted by admin; query-only (the orchestrator never
  # ingests at runtime). Idempotent (grant_cap upserts the cap).
  @doc false
  def grant_orchestrator_kb_query(autosvc_uri, workspace_uri, admin_ctx) do
    cap = Capability.cap(:agent, Ezagent.Behavior.Kb, :query, :any, workspace_uri)

    case Ezagent.Identity.grant_cap(autosvc_uri, cap, admin_ctx.caller) do
      :ok ->
        Logger.info("autosvc-seed: granted kb.query to #{URI.to_string(autosvc_uri)}")
        :ok

      {:error, reason} ->
        {:error, {:grant_kb_query_failed, reason}}
    end
  end

  # Create a LIVE public_view session in the current BEAM (recipe §2: the
  # public controller gates on the live session slice before join, so the
  # session must be live in the serving node). Idempotent.
  defp ensure_public_view_session(ws, short) do
    session_uri = EzUri.new!("session://#{ws}/default/#{short}")

    {:ok, tmpl} =
      Ezagent.Entity.SessionTemplate.persist_version_as_system(
        %{name: "autosvc-#{short}", public_view: true},
        ws
      )

    case Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
           uri: session_uri,
           behaviors: Ezagent.Entity.Session.socialware_behaviors()
         }) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    {:ok, _} =
      Ezagent.Behavior.Session.ConfigActions.system_set_working_copy(session_uri, %{
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
        behavior: Ezagent.Behavior.Session,
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

    _ = Ezagent.Behavior.Session.Membership.mount_participation_caps(session_uri, member_uri)
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

    %{
      customer: "#{base}/socialware/chat?session_uri=#{enc}",
      operator: "#{String.replace(base, "//", "//world.")}/sessions?session=#{enc}"
    }
  end
end
