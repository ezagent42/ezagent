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

  defp manage_cap(agent, workspace, granter),
    do: CreatorGrant.manage_cap(:agent, agent, workspace, granter)

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
    ctx = %{caller: owner, caps: MapSet.new([manage_cap(agent, workspace, owner)])}

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
    ctx = %{caller: owner, caps: MapSet.new([manage_cap(agent, workspace, owner)])}

    assert {:ok, %{status: :authenticated}} = DomainAgent.read_credential_status(agent, ctx)
    refute kind_live?(agent)
  end

  # ── #160 regression gate: co-tenant denied, learns NOTHING ───────

  test "a co-tenant WITHOUT the target's Manage cap is denied and learns nothing (the #160 gate)",
       %{agent: agent, config_dir: config_dir, flavor: flavor} do
    :ok = seed(agent, config_dir, flavor)
    write_cred(config_dir)
    cotenant = user("cotenant")
    ctx = %{caller: cotenant, caps: MapSet.new()}

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
    ctx = %{caller: granter, caps: MapSet.new([manage_cap(other, workspace, granter)])}

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
    ctx = %{caller: granter, caps: MapSet.new([manage_cap(foreign, foreign_ws, granter)])}

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
      :ok =
        AgentFlavorRegistry.register(%{
          flavor: "cc-custom",
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

      :ok
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

    defp seed_cc_custom(agent, provider) do
      :ok = Ezagent.AgentFlavorAttributes.put(agent, "cc-custom")

      respawn_data =
        case provider do
          p when is_binary(p) and p != "" ->
            %{"flavor" => "cc-custom", "provider" => p}

          _ ->
            %{"flavor" => "cc-custom"}
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
         %{agent: agent, workspace: workspace} do
      :ok = seed_cc_custom(agent, "kimi")
      owner = user("owner")
      ctx = %{caller: owner, caps: MapSet.new([manage_cap(agent, workspace, owner)])}

      refute kind_live?(agent)

      assert {:ok, %{status: :missing, flavor: "cc-custom"}} =
               DomainAgent.read_credential_status(agent, ctx)

      System.put_env("MOONSHOT_API_KEY", "test-only-key")

      assert {:ok, %{status: :authenticated, flavor: "cc-custom"}} =
               DomainAgent.read_credential_status(agent, ctx)

      refute kind_live?(agent), "read_credential_status must NOT activate the cold agent"
    end

    test "persisted cc-custom agent with NO provider → :unknown (never an alarm)",
         %{agent: agent, workspace: workspace} do
      :ok = seed_cc_custom(agent, nil)
      owner = user("owner")
      ctx = %{caller: owner, caps: MapSet.new([manage_cap(agent, workspace, owner)])}

      assert {:ok, %{status: :unknown, flavor: "cc-custom"}} =
               DomainAgent.read_credential_status(agent, ctx)

      refute kind_live?(agent)
    end
  end
end
