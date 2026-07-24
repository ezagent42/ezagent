defmodule Ezagent.Domain.AgentCredentialStatusTest do
  @moduledoc """
  #160 — `Ezagent.Domain.Agent.read_credential_status/2` cap-gating + non-activation.

  This is the #160 regression gate. `read_credential_status/2` authorizes ONCE with
  the SAME `cap(:agent, Manage, :read_cascade)` gate as `read_config/3` (owner +
  ws-admin only), BEFORE any sandbox/slice read — so a co-tenant WITHOUT the
  target's Manage cap is denied and learns NOTHING. The end-to-end wiring
  (authorize → sandbox `config_dir` → flavor resolve → flavor probe) is exercised
  through a FAKE file-credentialled flavor (so the test doesn't depend on the cc
  plugin being loaded in the session VM; cc's own classification is covered by
  `EzagentPluginCc` tests). Every read is on a COLD agent (`KindRegistry.lookup ==
  :error` before AND after) — the probe never force-activates.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.CreatorGrant
  alias Ezagent.Domain.Agent, as: DomainAgent
  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.SnapshotStore

  # A file-credentialled fake flavor whose probe reflects REAL on-disk presence of
  # a `cred` file in the agent's config_dir — so the read is a true end-to-end.
  defmodule FileTC do
    @behaviour Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: "FAKE_HOME"
    def credential_relpaths, do: ["cred"]
    def secret_relpaths, do: ["cred"]
    def auth_failure_signals, do: []

    def credential_status(dir, _opts) do
      if is_binary(dir) and File.exists?(Path.join(dir, "cred")),
        do: %{status: :authenticated, detail: nil, expires_at: nil},
        else: %{status: :missing, detail: "logged out", expires_at: nil}
    end
  end

  setup do
    flavor = "credstat-cc-#{System.unique_integer([:positive])}"
    :ok = AgentFlavorRegistry.register(%{flavor: flavor, kind: FileTC, template_class: FileTC})

    agent = Ezagent.URI.entity(:team_alpha, :agent, "cold-#{System.unique_integer([:positive])}")
    workspace = Ezagent.Capability.workspace_of(agent)

    config_dir = Path.join(System.tmp_dir!(), "credstat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(config_dir)
    on_exit(fn -> File.rm_rf(config_dir) end)

    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent)),
           "precondition: agent Kind must be cold"

    %{agent: agent, workspace: workspace, flavor: flavor, config_dir: config_dir}
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp kind_live?(uri), do: match?({:ok, _pid}, Ezagent.KindRegistry.lookup(URI.to_string(uri)))

  defp user(name),
    do: Ezagent.URI.entity(:team_alpha, :user, "#{name}-#{System.unique_integer([:positive])}")

  defp manage_cap(agent, workspace, granter) do
    requested = CreatorGrant.manage_cap(:agent, agent, workspace, granter)
    authority = install_test_authority!(agent, :agent)
    cap = authority_signed_cap!(authority, granter, requested)
    :ok = license_holder!(granter)
    cap
  end

  defp license_holder!(holder) do
    case Ezagent.Users.create_read_only(holder, [self_license_cap!(holder)]) do
      {:ok, _} -> :ok
      {:error, changeset} -> raise "failed to license test holder: #{inspect(changeset.errors)}"
    end
  end

  # Seed the agent's durable sandbox slice (config_dir) as a snapshot and prime the
  # flavor fast-path ETS — emulating an agent that WAS spawned (so flavor + config_dir
  # resolve) but whose Kind is NOT live now. NO Kind spawn, so the agent stays cold
  # and every read resolves cold-path / non-activating (the #160 non-activation gate).
  defp seed(agent, config_dir, flavor) do
    :ok = Ezagent.AgentFlavorAttributes.put(agent, flavor)

    {:ok, _} =
      SnapshotStore.write(
        agent,
        %{
          sandbox: %{
            config_dir_path: config_dir,
            template_class: nil,
            respawn_template_data: %{flavor: flavor},
            pty_phase: nil
          },
          identity: %{caps: MapSet.new()}
        },
        kind_type: :agent
      )

    :ok
  end

  defp write_cred(config_dir), do: File.write!(Path.join(config_dir, "cred"), "token")

  # ── authorization: owner allowed ─────────────────────────────────

  test "owner (holds Manage cap) reads status; a logged-out agent → :missing, WITHOUT activating",
       %{agent: agent, workspace: workspace, flavor: flavor, config_dir: config_dir} do
    :ok = seed(agent, config_dir, flavor)
    owner = user("owner")

    ctx = %{
      caller: owner,
      authenticated_principal: owner,
      caps: MapSet.new([manage_cap(agent, workspace, owner)])
    }

    refute kind_live?(agent)

    assert {:ok, status} = DomainAgent.read_credential_status(agent, ctx)
    assert status.status == :missing
    assert status.flavor == flavor
    assert %DateTime{} = status.checked_at

    refute kind_live?(agent), "read_credential_status must NOT activate the cold agent"
  end

  test "owner reads :authenticated when the credential file is present (end-to-end)",
       %{agent: agent, workspace: workspace, flavor: flavor, config_dir: config_dir} do
    :ok = seed(agent, config_dir, flavor)
    write_cred(config_dir)
    owner = user("owner")

    ctx = %{
      caller: owner,
      authenticated_principal: owner,
      caps: MapSet.new([manage_cap(agent, workspace, owner)])
    }

    assert {:ok, %{status: :authenticated}} = DomainAgent.read_credential_status(agent, ctx)
    refute kind_live?(agent)
  end

  # ── #160 regression gate: co-tenant denied, learns NOTHING ───────

  test "a co-tenant WITHOUT the target's Manage cap is denied and learns nothing (the #160 gate)",
       %{agent: agent, config_dir: config_dir, flavor: flavor} do
    :ok = seed(agent, config_dir, flavor)
    write_cred(config_dir)
    cotenant = user("cotenant")
    :ok = license_holder!(cotenant)
    ctx = %{caller: cotenant, authenticated_principal: cotenant, caps: MapSet.new()}

    # EXACTLY {:error, :unauthorized} — no status map, no config_dir, no flavor leak.
    assert DomainAgent.read_credential_status(agent, ctx) == {:error, :unauthorized}
    refute kind_live?(agent), "deny path must not activate the agent"
  end

  # ── instance-scope: a cap over a DIFFERENT agent does not authorize ──

  test "a Manage cap over a DIFFERENT agent does not authorize the target (instance-scoped)",
       %{agent: agent, workspace: workspace, config_dir: config_dir, flavor: flavor} do
    :ok = seed(agent, config_dir, flavor)

    other = Ezagent.URI.entity(:team_alpha, :agent, "other-#{System.unique_integer([:positive])}")
    granter = user("og")

    ctx = %{
      caller: granter,
      authenticated_principal: granter,
      caps: MapSet.new([manage_cap(other, workspace, granter)])
    }

    assert {:error, :unauthorized} = DomainAgent.read_credential_status(agent, ctx)
    refute kind_live?(agent)
  end

  # ── cross-workspace: a cap for another workspace's agent is denied ──

  test "a Manage cap for an agent in a DIFFERENT workspace does not authorize (cross-workspace)",
       %{agent: agent, config_dir: config_dir, flavor: flavor} do
    :ok = seed(agent, config_dir, flavor)

    foreign =
      Ezagent.URI.entity(:team_beta, :agent, "foreign-#{System.unique_integer([:positive])}")

    foreign_ws = Ezagent.Capability.workspace_of(foreign)
    granter = user("fg")

    ctx = %{
      caller: granter,
      authenticated_principal: granter,
      caps: MapSet.new([manage_cap(foreign, foreign_ws, granter)])
    }

    assert {:error, :unauthorized} = DomainAgent.read_credential_status(agent, ctx)
    refute kind_live?(agent)
  end

  # ── cc-custom: the persisted backend profile drives the status read ──
  #
  # A cc-custom agent's credential is the SELECTED backend profile's env var
  # (kimi → MOONSHOT_API_KEY), never an on-disk login. The profile name rides
  # in the durable `:sandbox` slice's `respawn_template_data["provider"]`; the
  # status read must thread it to the flavor probe as `:backend_profile` —
  # non-activating, like `trusted_config_dir/1`. `FakeCcCustomTemplate` (test
  # support) mirrors the real `CcCustomAgent` contract (plugin_cc is not a
  # domain_agent dep).
  describe "cc-custom persisted backend profile" do
    setup do
      # UNIQUE per test (never the real "cc-custom"): at umbrella root plugin_cc
      # boots first and owns "cc-custom" → CcCustomAgent, and
      # `AgentFlavorRegistry.register/1` raises on a divergent re-registration.
      # Shadows the outer context's `:flavor` — within this describe "flavor"
      # IS the fake cc-custom flavor.
      flavor = "cc-custom-fake-#{System.unique_integer([:positive])}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Agent.FakeCcCustomTemplate,
          template_class: Ezagent.Agent.FakeCcCustomTemplate
        })

      # The `:flavor` UriQuery resolver is owned by ezagent_domain_session,
      # which is NOT started in this app's test env — prime a resolver for the
      # cc-custom flavor reads (mirroring `AgentTest`'s save/restore pattern).
      Ezagent.UriQuery.init()
      previous = :ets.lookup(Ezagent.UriQuery.table(), :flavor)
      :ets.delete(Ezagent.UriQuery.table(), :flavor)

      :ets.insert(Ezagent.UriQuery.table(), {:flavor, &resolve_cc_custom_flavor/1})

      on_exit(fn ->
        :ets.delete(Ezagent.UriQuery.table(), :flavor)

        for entry <- previous do
          :ets.insert(Ezagent.UriQuery.table(), entry)
        end
      end)

      key_previous = System.get_env("MOONSHOT_API_KEY")
      System.delete_env("MOONSHOT_API_KEY")

      on_exit(fn ->
        if key_previous,
          do: System.put_env("MOONSHOT_API_KEY", key_previous),
          else: System.delete_env("MOONSHOT_API_KEY")
      end)

      %{flavor: flavor}
    end

    # The production chain's non-activating rungs: launch attribute → durable
    # snapshot (the live-Kind rung is unnecessary here — the agent stays cold).
    defp resolve_cc_custom_flavor(%URI{} = uri) do
      case Ezagent.AgentFlavorAttributes.get(uri) do
        {:ok, _flavor} = ok -> ok
        :none -> Ezagent.AgentFlavorResolver.flavor_from_durable_snapshot(uri)
      end
    end

    defp resolve_cc_custom_flavor(_), do: :none

    defp seed_cc_custom(agent, flavor, provider) do
      :ok = Ezagent.AgentFlavorAttributes.put(agent, flavor)

      respawn_data =
        case provider do
          p when is_binary(p) and p != "" ->
            %{"flavor" => flavor, "provider" => p}

          _ ->
            %{"flavor" => flavor}
        end

      {:ok, _} =
        SnapshotStore.write(
          agent,
          %{
            sandbox: %{
              config_dir_path: nil,
              template_class: nil,
              respawn_template_data: respawn_data,
              pty_phase: nil
            },
            identity: %{caps: MapSet.new()}
          },
          kind_type: :agent
        )

      :ok
    end

    test "persisted provider kimi, key unset → :missing; key set → :authenticated (non-activating)",
         %{agent: agent, workspace: workspace, flavor: flavor} do
      :ok = seed_cc_custom(agent, flavor, "kimi")
      owner = user("owner")

      ctx = %{
        caller: owner,
        authenticated_principal: owner,
        caps: MapSet.new([manage_cap(agent, workspace, owner)])
      }

      refute kind_live?(agent)

      assert {:ok, %{status: :missing, flavor: ^flavor}} =
               DomainAgent.read_credential_status(agent, ctx)

      System.put_env("MOONSHOT_API_KEY", "test-only-key")

      assert {:ok, %{status: :authenticated, flavor: ^flavor}} =
               DomainAgent.read_credential_status(agent, ctx)

      refute kind_live?(agent), "read_credential_status must NOT activate the cold agent"
    end

    test "persisted cc-custom agent with NO provider → :unknown (never an alarm)",
         %{agent: agent, workspace: workspace, flavor: flavor} do
      :ok = seed_cc_custom(agent, flavor, nil)
      owner = user("owner")

      ctx = %{
        caller: owner,
        authenticated_principal: owner,
        caps: MapSet.new([manage_cap(agent, workspace, owner)])
      }

      assert {:ok, %{status: :unknown, flavor: ^flavor}} =
               DomainAgent.read_credential_status(agent, ctx)

      refute kind_live?(agent)
    end
  end

  # ── §6.3 directory batch: O(slice-types) queries, CONSTANT across N ──
  #
  # `read_credential_statuses/3` renders a whole agent directory. It must read every
  # durable slice it classifies from — `:sandbox` (config-dir / backend-profile /
  # flavor), `:api_keys` (credential slice), `:curl_agent` (curl's durable flavor) —
  # in ONE `read_durable_many/3` PER SLICE TYPE, i.e. O(slice-types) queries TOTAL,
  # never O(agents). This gate counts EVERY `kind_snapshots` query (not only the
  # batched shape, so a scalar N+1 cannot hide) under REAL caps with a mix of a
  # file-credentialled and a slice-credentialled agent, and proves the count is
  # CONSTANT as the directory grows.

  # A slice-credentialled (curl-like) fake flavor — creds in the `:api_keys` slice,
  # durable flavor in the `:curl_agent` slice.
  defmodule SliceTC do
    @behaviour Ezagent.Agent.CredentialSliceAdapter
    def credential_slice, do: :api_keys
    def materialize_credential_slice(_uri, _data), do: :ok
  end

  # Mint a Manage cap WITHOUT re-licensing the holder (the shared `manage_cap/3`
  # licenses on every call, which would raise on the 2nd agent for one owner).
  defp manage_cap_no_license(agent, workspace, granter) do
    requested = CreatorGrant.manage_cap(:agent, agent, workspace, granter)
    authority = install_test_authority!(agent, :agent)
    authority_signed_cap!(authority, granter, requested)
  end

  defp seed_file_agent(owner, flavor) do
    agent =
      Ezagent.URI.entity(:team_alpha, :agent, "cold-file-#{System.unique_integer([:positive])}")

    config_dir = Path.join(System.tmp_dir!(), "credstat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(config_dir)
    on_exit(fn -> File.rm_rf(config_dir) end)
    # durable :sandbox (config_dir + flavor via respawn), no cred file on disk → :missing
    :ok = seed(agent, config_dir, flavor)
    {agent, manage_cap_no_license(agent, Ezagent.Capability.workspace_of(agent), owner), :missing}
  end

  defp seed_slice_agent(owner, slice_flavor) do
    agent =
      Ezagent.URI.entity(:team_alpha, :agent, "cold-slice-#{System.unique_integer([:positive])}")

    {:ok, _} =
      SnapshotStore.write(
        agent,
        %{
          curl_agent: %{flavor: slice_flavor},
          api_keys: %{keys: %{"openai" => "sk-x"}},
          identity: %{caps: MapSet.new()}
        },
        kind_type: :agent
      )

    {agent, manage_cap_no_license(agent, Ezagent.Capability.workspace_of(agent), owner),
     :authenticated}
  end

  # An AUTHORIZED agent whose durable state resolves NO flavor (no `:sandbox`
  # template/respawn, no `:curl_agent` `:flavor`) → `:unknown`. Exercises codex #1:
  # a prefetched nil flavor must NOT fall back to a per-agent durable read.
  defp seed_unresolved_flavor_agent(owner) do
    agent =
      Ezagent.URI.entity(:team_alpha, :agent, "cold-unres-#{System.unique_integer([:positive])}")

    {:ok, _} =
      SnapshotStore.write(agent, %{api_keys: %{keys: %{}}, identity: %{caps: MapSet.new()}},
        kind_type: :agent
      )

    {agent, manage_cap_no_license(agent, Ezagent.Capability.workspace_of(agent), owner), :unknown}
  end

  # A DENIED agent (the caller holds NO Manage cap for it) with a real snapshot —
  # filter-first must EXCLUDE it (absent from the result) AND never batch-read its
  # slices. Exercises codex #2: a denied row must not cost a caller-caps reload.
  defp seed_denied_agent do
    agent =
      Ezagent.URI.entity(:team_alpha, :agent, "cold-denied-#{System.unique_integer([:positive])}")

    {:ok, _} =
      SnapshotStore.write(
        agent,
        %{
          sandbox: %{config_dir_path: "/x", template_class: nil, respawn_template_data: nil},
          api_keys: %{keys: %{"secret" => "leak"}},
          identity: %{caps: MapSet.new()}
        },
        kind_type: :agent
      )

    agent
  end

  # Count EVERY authorization + batch Repo query — kind_snapshots AND `users` AND
  # the authority table. A per-denied caller-caps reload hides in `users`/authority
  # queries, INVISIBLE to a kind_snapshots-only counter (codex round-4 #2).
  defp count_authz_and_batch_queries(fun) do
    test_pid = self()
    handler = "q-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ezagent_core, :repo, :query],
      fn _e, _m, meta, _c ->
        # Only the SYNCHRONOUS read path's own queries (this test process) — excludes
        # unrelated async/background queries that would make the count non-deterministic.
        if self() == test_pid do
          sql = to_string(meta[:query] || "")

          if sql =~ "kind_snapshots" or sql =~ ~s("users") or sql =~ "kind_cap_authorities",
            do: send(test_pid, :q)
        end
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {drain_q(0), result}
  end

  defp drain_q(n) do
    receive do
      :q -> drain_q(n + 1)
    after
      150 -> n
    end
  end

  # The caller holds its Manage caps IN THE STORE (`users.caps_json`) alongside a
  # current self-license — so the batch authorizes from the FRESH store
  # (`EntityCaps.load/1`), NEVER from the caller-supplied inline caps.
  defp owner_with_store_caps(owner, manage_caps) do
    {:ok, _} = Ezagent.Users.create_read_only(owner, [self_license_cap!(owner) | manage_caps])
    :ok
  end

  describe "directory batch (§6.3)" do
    setup do
      slice_flavor = "credstat-curl-#{System.unique_integer([:positive])}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: slice_flavor,
          kind: SliceTC,
          template_class: SliceTC
        })

      %{slice_flavor: slice_flavor}
    end

    test "query count CONSTANT as the DENIED set grows — no per-denied caller reload (finding-2)",
         %{flavor: file_flavor, slice_flavor: slice_flavor} do
      owner = user("dir-owner")

      # AUTHORIZED set (→ the caller's cap count → EntityCaps.load cost) is held FIXED
      # at 3 (file → :missing, slice → :authenticated, unresolved-flavor → :unknown,
      # which also exercises finding-1: a prefetched nil flavor never falls back to a
      # per-agent read); only the DENIED set grows. Constant-as-denied-grows IS "no
      # per-denied reload" — and it sidesteps the EntityCaps.load-scales-with-cap-count
      # trap that a growing AUTHORIZED set would introduce.
      authorized =
        [
          seed_file_agent(owner, file_flavor),
          seed_slice_agent(owner, slice_flavor),
          seed_unresolved_flavor_agent(owner)
        ]

      :ok = owner_with_store_caps(owner, Enum.map(authorized, fn {_u, c, _s} -> c end))

      run = fn n_denied ->
        denied = for _ <- 1..n_denied, do: seed_denied_agent()
        uris = Enum.map(authorized, fn {u, _c, _s} -> u end) ++ denied
        # Inline caps are IRRELEVANT to the batch now (it reads the fresh store).
        ctx = %{caller: owner, authenticated_principal: owner, caps: MapSet.new()}

        {queries, statuses} =
          count_authz_and_batch_queries(fn ->
            DomainAgent.read_credential_statuses(uris, ctx)
          end)

        for {uri, _c, want} <- authorized do
          assert %{status: ^want} = Map.fetch!(statuses, URI.to_string(uri))
        end

        for d <- denied, do: refute(Map.has_key?(statuses, URI.to_string(d)))
        for {uri, _c, _s} <- authorized, do: refute(kind_live?(uri))
        queries
      end

      # Warm one-time authority-verification caches first (ETS), so the two measured
      # runs differ ONLY in the denied count, not in cold-vs-warm authority loads.
      _warmup = run.(2)
      q_2denied = run.(2)
      q_5denied = run.(5)

      assert q_2denied == q_5denied,
             "total authz+batch query count (kind_snapshots + users + authority) must be " <>
               "CONSTANT as the denied set grows (2 denied → #{q_2denied}, 5 denied → " <>
               "#{q_5denied}) — a per-denied caller-caps reload regressed finding-2"
    end

    test "authorizes against the FRESH store, NEVER the stale inline caps (over-auth / TOCTOU)",
         %{flavor: file_flavor} do
      owner = user("dir-owner")
      {x_uri, x_cap, _} = seed_file_agent(owner, file_flavor)
      # Y's cap is a REVOKED-from-store cap that lingers in the mount snapshot: the
      # caller holds it ONLY inline, NOT in the store (single-cap revoke removes it
      # from the store without a generation bump — authority.ex:110).
      {y_uri, y_cap, _} = seed_file_agent(owner, file_flavor)

      # Store: X only. Inline (ctx.caps): X AND the stale Y.
      :ok = owner_with_store_caps(owner, [x_cap])
      ctx = %{caller: owner, authenticated_principal: owner, caps: MapSet.new([x_cap, y_cap])}

      statuses = DomainAgent.read_credential_statuses([x_uri, y_uri], ctx)

      # X (in the fresh store) is shown; Y (inline-only / revoked) is DENIED — the
      # batch must NOT resurrect revoked authority from the stale inline set.
      # (FAILS on an inline-caps filter, which would still authorize Y.)
      assert Map.has_key?(statuses, URI.to_string(x_uri))
      refute Map.has_key?(statuses, URI.to_string(y_uri))
    end

    test "batch presence ⟺ scalar read_credential_status/3 decision (differential parity)",
         %{flavor: file_flavor, slice_flavor: slice_flavor} do
      owner = user("dir-owner")
      {x_uri, x_cap, _} = seed_file_agent(owner, file_flavor)
      {y_uri, _y_cap, _} = seed_slice_agent(owner, slice_flavor)
      {z_uri, z_cap, _} = seed_file_agent(owner, file_flavor)

      # Store holds caps for X and Z, NOT Y.
      :ok = owner_with_store_caps(owner, [x_cap, z_cap])
      ctx = %{caller: owner, authenticated_principal: owner, caps: MapSet.new()}

      statuses = DomainAgent.read_credential_statuses([x_uri, y_uri, z_uri], ctx)

      # Pins the reconstructed predicate against the REAL scalar gate (guards any
      # check the batch predicate might miss — Match internals, verified_set, admin
      # all-caps): batch presence must EQUAL the scalar authorization, agent-by-agent.
      for uri <- [x_uri, y_uri, z_uri] do
        scalar_ok? = match?({:ok, _}, DomainAgent.read_credential_status(uri, ctx))

        assert Map.has_key?(statuses, URI.to_string(uri)) == scalar_ok?,
               "batch/scalar authorization disagree for #{URI.to_string(uri)}"
      end
    end
  end
end
