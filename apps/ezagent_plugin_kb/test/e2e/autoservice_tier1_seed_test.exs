defmodule EzagentPluginKb.E2E.AutoserviceTier1SeedTest do
  @moduledoc """
  AutoService Tier-1 seed — deterministic regression for the seed wiring
  scenario-13 (docs/e2e/scenario-13-autoservice-end-to-end.md) needs to make
  S2/S3 judgeable.

  This test exercises the EXACT seed module (`Code.require_file` of
  `scripts/autoservice_tier1_seed.exs`), not a parallel hand-built wiring — so a
  green here means the SHIPPED seed wires the chain (advisor #4).

  It proves the two things scenario-13 says have "no existing proof", kept as
  DISTINCT claims (advisor #2):

    * **S2a/S2b (routing)** — the seeded session-scoped `always → AutoService
      agent` rule resolves a customer's BARE message (no @mention) to the agent
      receiver. scenario-04 found new sessions route nothing without an
      @mention; this is the proof the seed closes that gap.

    * **S3 retrieval soul (deterministic half)** — `kb.query` against the seeded
      kb-agent, carrying the orchestrator's seeded `kb.query` cap, returns the
      `ZEPHYR-7731` fact that is ONLY in the ingested corpus (excludes the model
      prior). Audit corroboration here is the `[:ezagent,:authz,:granted]`
      telemetry SIGNAL (the source the audit writer persists) — NOT the
      persisted `invocations` row, because `Audit.Writer` is disabled in `:test`.
      The persisted-row proof (scenario-12 step-5) is a live-stack concern,
      captured in `evidence/scenario-13/`.

  What this test does NOT prove (the reported GAP, by design): the ANSWER-level
  soul — a live `claude` cc-orchestrator weaving the fact into a CHAT REPLY
  through the customer surface. That rides cc's PTY/startup blockers
  (scenario-05 / GAP-4) and is verified (or its blocker reported) on the live
  disposable stack, not here.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Routing.Resolver
  alias Ezagent.URI, as: EzUri

  @seed Path.expand("../../../../scripts/autoservice_tier1_seed.exs", __DIR__)

  setup_all do
    Code.require_file(@seed)
    :ok
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    :ok
  end

  @tag :integration
  test "seed wires the Tier-1 chain: bare message routes to agent + KB-only fact retrievable + audited" do
    skip_if_no_entity_spawn(fn ->
      ws = "autosvc-#{System.unique_integer([:positive])}"

      {:ok, seed} =
        Ezagent.AutoService.Tier1Seed.seed(
          ws: ws,
          register_recipes: true,
          kb_flavor: "kb-native-test-#{System.unique_integer([:positive])}",
          autoservice_flavor: "autosvc-test-#{System.unique_integer([:positive])}",
          autoservice_role: "autosvc-role-#{System.unique_integer([:positive])}"
        )

      session_uri = seed.session_uri
      autosvc_uri = seed.autoservice_agent_uri

      # The generic test flavor IS create_agent-supported (unlike live cc), so
      # the AutoService agent is created + granted + joined. (On a live node the
      # cc-orchestrator path reports {:blocked, :role_unsupported_for_flavor}.)
      assert seed.autoservice_agent_status == :created,
             "expected the (non-cc) AutoService agent to be created; got " <>
               inspect(seed.autoservice_agent_status)

      # ── web anonymous access (S1) — assert only if socialware is loadable in this dep
      # set; otherwise it is covered by the live browser run (the seed always
      # installs a socialware definition with web_anon_access). ──────────────
      if Code.ensure_loaded?(Ezagent.Socialware.PublicView) do
        assert Ezagent.Socialware.PublicView.web_anon_access?(session_uri),
               "the seeded session must allow anonymous web access (S1 anon landing precondition)"
      end

      # ── S2a/S2b: a BARE customer message (no @mention) resolves to the
      # AutoService agent via the seeded always→agent rule. ──────────────────
      customer = EzUri.new!("entity://#{ws}/user/anon-customer")

      bare_msg =
        %{
          Ezagent.Message.new(
            customer,
            %{text: "How do I reach the priority support hotline?"},
            mentions: []
          )
          | session_uri: session_uri,
            workspace_uri: "workspace://#{ws}"
        }

      recipients =
        Resolver.resolve(bare_msg, session_uri, [autosvc_uri, customer],
          workspace_uri: EzUri.workspace_of(session_uri)
        )

      recipient_strs = Enum.map(recipients, &URI.to_string/1)

      assert URI.to_string(autosvc_uri) in recipient_strs,
             "a BARE (un-@-mentioned) customer message must route to the AutoService " <>
               "agent via the seeded always→agent rule (S2a/S2b). Got: #{inspect(recipient_strs)}"

      # Session-scope negative: the rule is `in_session(this)`, NOT a global
      # `always`. A bare message in a DIFFERENT session must NOT route to the
      # AutoService agent — otherwise the rule would hijack every session's
      # un-mentioned traffic (codex S2a adversarial probe).
      other_session = EzUri.new!("session://#{ws}/default/some-other")

      other_msg =
        %{
          Ezagent.Message.new(customer, %{text: "unrelated chatter"}, mentions: [])
          | session_uri: other_session,
            workspace_uri: "workspace://#{ws}"
        }

      other_recipients =
        Resolver.resolve(other_msg, other_session, [autosvc_uri, customer],
          workspace_uri: EzUri.workspace_of(other_session)
        )
        |> Enum.map(&URI.to_string/1)

      refute URI.to_string(autosvc_uri) in other_recipients,
             "the always→agent rule must be SESSION-SCOPED — a bare message in another " <>
               "session must NOT reach the AutoService agent. Got: #{inspect(other_recipients)}"

      # ── S3 retrieval soul: kb.query carrying the orchestrator's SEEDED cap
      # returns the KB-only fact (ZEPHYR-7731). ──────────────────────────────
      fact = Ezagent.AutoService.Tier1Seed.kb_fact_token()
      probe = Ezagent.AutoService.Tier1Seed.kb_probe_query()

      # Read back the caps the AGENT ACTUALLY HOLDS in its identity slice — the
      # SAME source the live orchestrator reads
      # (SessionManager.load_orchestrator_caps → Identity.list_caps_for). Using
      # these (not a hand-supplied set) proves the seed's grant lands where the
      # live path looks (closes the cap circularity; matches the live S3 cap
      # source).
      held = Ezagent.Identity.list_caps_for(autosvc_uri)

      assert Enum.any?(held, fn c ->
               Map.get(c, :behavior) == Ezagent.ActionSet.Kb and Map.get(c, :action) == :query
             end),
             "the seeded AutoService agent must HOLD kb.query in its identity slice " <>
               "(the live orchestrator's cap source). Held: #{inspect(MapSet.to_list(held))}"

      opts = [
        caller: autosvc_uri,
        caps: held,
        workspace_uri: seed.workspace_uri
      ]

      # ── S3 audit corroboration: the `[:ezagent, :authz, :granted]` telemetry
      # event — the SOURCE the audit `invocations` writer persists — fires for
      # the kb.query dispatch. We assert the SIGNAL (deterministic), not the
      # persisted row: `Ezagent.Audit.Writer` is deliberately disabled in :test
      # (`@writers_skipped_in_test`), so the persisted-row check is a live-stack
      # concern (scenario-12 queries live PG `invocations`). ──────────────────
      kb_uri_str = URI.to_string(seed.kb_agent_uri)
      handler_id = "autosvc-tier1-authz-#{System.unique_integer([:positive])}"
      parent = self()

      # Forward ONLY the kb-agent's :query granted event so the assert_receive
      # cannot match an unrelated authz decision.
      :telemetry.attach(
        handler_id,
        [:ezagent, :authz, :granted],
        fn _event, _measure, meta, _cfg ->
          target = meta |> Map.get(:target) |> to_string()

          if Map.get(meta, :action) in [:query, "query"] and
               String.contains?(target, kb_uri_str) do
            send(parent, {:authz_granted_kb_query, meta})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{hits: hits}} =
               Ezagent.Session.Config.execute(
                 "kb_query",
                 %{"kb_agent" => seed.kb_agent_name, "query" => probe, "k" => 5},
                 opts[:caller],
                 opts[:workspace_uri]
               )

      assert Enum.any?(hits, fn h -> h.text =~ fact end),
             "the KB answer must contain the fact only present in the ingested corpus " <>
               "(#{fact}) — proving retrieval, not model prior. Hits: #{inspect(hits)}"

      assert_receive {:authz_granted_kb_query, _meta},
                     1000,
                     "expected an authz :granted telemetry event (the audit invocation source) " <>
                       "for the kb-agent's kb.query dispatch"

      # ── Negative control: a DIFFERENT caller that holds NO caps (and supplies
      # none) is denied — pins the retrieval to the seeded cap, not an open door.
      # (The AutoService agent itself now HOLDS kb.query in its identity slice,
      # so it would pass even with an empty ctx cap set — hence a fresh capless
      # principal.) ──────────────────────────────────────────────────────────
      nobody = EzUri.new!("entity://#{ws}/user/nobody")

      no_cap_opts = [
        caller: nobody,
        caps: MapSet.new([]),
        workspace_uri: seed.workspace_uri
      ]

      assert {:error, {:gate_failed, :operation_caps, :unauthorized}} =
               Ezagent.Session.Config.execute(
                 "kb_query",
                 %{"kb_agent" => seed.kb_agent_name, "query" => probe, "k" => 5},
                 no_cap_opts[:caller],
                 no_cap_opts[:workspace_uri]
               ),
             "kb.query from a capless principal must be refused (the cap is load-bearing)"
    end)
  end

  @tag :integration
  test "seed is idempotent: a second run reuses the same URIs and does not duplicate the route" do
    skip_if_no_entity_spawn(fn ->
      ws = "autosvc-#{System.unique_integer([:positive])}"

      args = [
        ws: ws,
        register_recipes: true,
        kb_flavor: "kb-native-test-#{System.unique_integer([:positive])}",
        autoservice_flavor: "autosvc-test-#{System.unique_integer([:positive])}",
        autoservice_role: "autosvc-role-#{System.unique_integer([:positive])}"
      ]

      assert {:ok, a} = Ezagent.AutoService.Tier1Seed.seed(args)
      assert {:ok, b} = Ezagent.AutoService.Tier1Seed.seed(args)

      assert URI.to_string(a.kb_agent_uri) == URI.to_string(b.kb_agent_uri)
      assert URI.to_string(a.autoservice_agent_uri) == URI.to_string(b.autoservice_agent_uri)
      assert URI.to_string(a.session_uri) == URI.to_string(b.session_uri)
      assert a.rule_id == b.rule_id, "the always→agent route must not be duplicated on re-seed"
    end)
  end

  # Mirror kb_role_native_test: skip when the entity-spawn bootstrap is absent
  # (test isolation incomplete) rather than failing spuriously.
  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
