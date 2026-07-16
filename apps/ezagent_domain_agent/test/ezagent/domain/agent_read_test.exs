defmodule Ezagent.Domain.AgentReadTest do
  @moduledoc """
  SPEC `unified-non-activating-agent-read.md` §8 — the unified non-activating
  read interface `Ezagent.Domain.Agent.read_{config,caps,sandbox,status}`.

  Every assertion follows `config_no_activation_test.exs`: a COLD agent (URI
  valid, Kind NEVER spawned), with `KindRegistry.lookup == :error` BEFORE and
  AFTER each read — for ALL FOUR reads. Plus: two-route authz parity (§3.2 D3),
  the caps self-read exemption, wrong-target (instance-scope) denial, and the
  module-scoped "no hand-rolled Capability.matches?" assertion (§8.9) that the
  global p3 probe cannot make (it covers presentation surfaces, not the owner facade).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.CreatorGrant
  alias Ezagent.Domain.Agent, as: DomainAgent
  alias Ezagent.SnapshotStore
  alias Ezagent.Socialware.ConfigStore

  @config_key "advisor.behavior"

  setup do
    name = "cold-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    workspace = Ezagent.Capability.workspace_of(agent)

    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent)),
           "precondition: agent Kind must be cold"

    %{agent: agent, workspace: workspace}
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp kind_live?(uri), do: match?({:ok, _pid}, Ezagent.KindRegistry.lookup(URI.to_string(uri)))

  defp user(name),
    do: Ezagent.URI.entity(:team_alpha, :user, "#{name}-#{System.unique_integer([:positive])}")

  defp manage_cap(agent, workspace, granter) do
    cap = CreatorGrant.manage_cap(:agent, agent, workspace, granter)
    sign_cap(agent, granter, granter, cap)
  end

  defp sandbox_cap(agent, granter, grantee \\ nil) do
    cap = %Ezagent.Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Sandbox,
      action: :read,
      instance: Ezagent.URI.instance(agent),
      workspace_uri: Ezagent.Capability.workspace_of(agent),
      granted_by: granter,
      granted_at: DateTime.utc_now()
    }

    sign_cap(agent, granter, grantee || granter, cap)
  end

  defp list_caps_cap(entity, granter) do
    cap = %Ezagent.Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: Ezagent.URI.instance(entity),
      workspace_uri: Ezagent.Capability.workspace_of(entity),
      granted_by: granter,
      granted_at: DateTime.utc_now()
    }

    sign_cap(entity, granter, granter, cap)
  end

  defp sign_cap(target, granter, grantee, cap) do
    authority = install_test_authority!(target, :agent)
    authority_signed_cap_as!(authority, granter, grantee, cap)
  end

  # Seed the agent's durable config + sandbox + identity slices into a snapshot
  # (NO Kind spawn → agent stays cold), so all reads resolve cold-path.
  defp seed_agent_snapshot(agent, workspace, manager) do
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: :user,
        workspace_uri: workspace,
        subject_uri: agent,
        key: @config_key,
        body: %{"tone" => "decisive"},
        actor_uri: manager,
        source_turn_id: "cold:#{System.unique_integer([:positive])}"
      })

    {:ok, _} =
      SnapshotStore.write(
        agent,
        %{
          sandbox: %{
            config_dir_path: "/tmp/ez-cold/#{System.unique_integer([:positive])}",
            template_class: nil,
            respawn_template_data: %{project_cwd: "/work", flavor: "cc"},
            pty_phase: nil
          },
          identity: %{caps: MapSet.new()}
        },
        kind_type: :agent
      )

    :ok
  end

  # Persist a User caller's caps into users.caps_json (the User SSOT; caller
  # Kind stays COLD), so route 2 can authorize it without activating the Kind.
  defp seed_caller_slice_caps(caller, caps) do
    {:ok, _} = Ezagent.Users.create_read_only(caller, caps)

    :ok
  end

  # ── §8.1 — unified no-activation, all 4 reads ────────────────────

  test "read_config / read_caps / read_sandbox / read_status all resolve a COLD agent without activating it",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)

    inline =
      MapSet.new([
        manage_cap(agent, workspace, manager),
        sandbox_cap(agent, manager),
        list_caps_cap(agent, manager)
      ])

    ctx = %{caller: manager, caps: inline}

    refute kind_live?(agent)

    assert {:ok, cascade} = DomainAgent.read_config(agent, ctx)
    assert cascade.agent_uri == URI.to_string(agent)

    assert {:ok, state} = DomainAgent.read_config_key(agent, @config_key, ctx)
    assert state.effective_body == %{"tone" => "decisive"}

    assert {:ok, caps} = DomainAgent.read_caps(agent, ctx)
    assert is_list(caps)

    assert {:ok, sandbox} = DomainAgent.read_sandbox(agent, ctx)
    assert is_map(sandbox)
    assert sandbox.config_dir_path =~ "/tmp/ez-cold/"

    # status of a cold agent — not_found, non-activating by construction.
    assert %{phase: :not_found} = DomainAgent.read_status(agent)

    refute kind_live?(agent),
           "a read activated the cold agent — every read_* MUST be non-activating"
  end

  # ── §8.2 — unauthorized caller denied, no activation on deny path ─

  test "an unauthorized caller is denied on every cap-gated read, without activating",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)
    stranger = user("stranger")
    ctx = %{caller: stranger, caps: MapSet.new()}

    assert {:error, :unauthorized} = DomainAgent.read_config(agent, ctx)
    assert {:error, :unauthorized} = DomainAgent.read_caps(agent, ctx)
    assert {:error, :unauthorized} = DomainAgent.read_sandbox(agent, ctx)

    refute kind_live?(agent), "deny path must not activate the agent"
  end

  # ── §8.3 — wrong-target (instance scope) ─────────────────────────

  test "a cap over a DIFFERENT agent does not authorize config/sandbox of the target (instance-scoped)",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)

    other = Ezagent.URI.entity(:team_alpha, :agent, "other-#{System.unique_integer([:positive])}")
    other_granter = user("og")

    wrong_caps =
      MapSet.new([manage_cap(other, workspace, other_granter), sandbox_cap(other, other_granter)])

    ctx = %{caller: other_granter, caps: wrong_caps}

    assert {:error, :unauthorized} = DomainAgent.read_config(agent, ctx)
    assert {:error, :unauthorized} = DomainAgent.read_sandbox(agent, ctx)

    refute kind_live?(agent)
  end

  # ── §8.4 — caps self-read exemption ──────────────────────────────

  test "read_caps self-read exemption: caller == entity succeeds with no list_caps cap",
       %{agent: agent} do
    # The agent reading its OWN caps, holding NOTHING.
    ctx = %{caller: agent, caps: MapSet.new()}

    assert {:ok, caps} = DomainAgent.read_caps(agent, ctx)
    assert is_list(caps)
    refute kind_live?(agent)
  end

  # ── §8.5 — two-route authz parity (D3) ───────────────────────────

  test "route 1 — inline ctx.caps authorizes a caller holding NOTHING in its slice",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)

    worker = user("worker")
    # worker has NO slice caps — only inline self-authority (the #154 class).
    ctx = %{caller: worker, caps: MapSet.new([sandbox_cap(agent, manager, worker)])}

    assert {:ok, _} = DomainAgent.read_sandbox(agent, ctx)
    refute kind_live?(agent)
    refute kind_live?(worker)
  end

  test "route 2 — slice/snapshot caps authorize a COLD caller passing NO inline caps",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)

    user_caller = user("logged-in")
    # Persist the cap into the COLD caller's caps_json; pass NO inline caps. This is
    # the bug bare `holds_cap?` (slice-only, denies cold) would have produced —
    # EntityCaps' durable User fallback authorizes the cold caller.
    :ok = seed_caller_slice_caps(user_caller, [sandbox_cap(agent, manager, user_caller)])
    ctx = %{caller: user_caller, caps: MapSet.new()}

    refute kind_live?(user_caller), "precondition: caller Kind cold (route 2 reads its snapshot)"

    assert {:ok, _} = DomainAgent.read_sandbox(agent, ctx)
    refute kind_live?(agent)
    refute kind_live?(user_caller), "route 2 must NOT activate the caller's Kind"
  end

  test "neither route — no inline cap + no slice cap → unauthorized",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)

    nobody = user("nobody")
    ctx = %{caller: nobody, caps: MapSet.new()}

    assert {:error, :unauthorized} = DomainAgent.read_sandbox(agent, ctx)
    refute kind_live?(agent)
  end

  # ── §8.6 — two-route STRUCTURE lock (both routes honored) ─────────

  test "two-route structure lock: BOTH an inline-only caller AND a slice-only caller authorize (config)",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)

    # route 1 only — inline manage cap, empty slice.
    inline_only = user("inline")

    assert {:ok, _} =
             DomainAgent.read_config(agent, %{
               caller: inline_only,
               caps: MapSet.new([manage_cap(agent, workspace, manager)])
             })

    # route 2 only — slice manage cap, NO inline.
    slice_only = user("slice")
    requested = CreatorGrant.manage_cap(:agent, agent, workspace, manager)
    slice_cap = sign_cap(agent, manager, slice_only, requested)
    :ok = seed_caller_slice_caps(slice_only, [slice_cap])
    assert {:ok, _} = DomainAgent.read_config(agent, %{caller: slice_only, caps: MapSet.new()})

    # A refactor dropping EITHER route would fail one of the two assertions
    # above (locking out one caller class) — the §3.2 invariant.
    refute kind_live?(agent)
  end

  # ── §8.7 — render parity (shapes unchanged) ──────────────────────

  test "read_caps returns raw [%Capability{}] and read_sandbox returns the raw state map (render-parity)",
       %{agent: agent, workspace: workspace} do
    manager = user("mgr")
    :ok = seed_agent_snapshot(agent, workspace, manager)

    ctx = %{
      caller: manager,
      caps: MapSet.new([sandbox_cap(agent, manager), list_caps_cap(agent, manager)])
    }

    assert {:ok, caps} = DomainAgent.read_caps(agent, ctx)
    assert Enum.all?(caps, &match?(%Ezagent.Capability{}, &1))

    assert {:ok, sandbox} = DomainAgent.read_sandbox(agent, ctx)
    assert Map.has_key?(sandbox, :config_dir_path)
  end

  # ── §8.9 — module-scoped no hand-rolled Capability.matches? ───────

  test "Domain.Agent source contains zero Capability.matches? (match routes through caps_authorize?)" do
    path = Path.expand("../../../lib/ezagent/domain/agent.ex", __DIR__)
    src = File.read!(path)

    refute src =~ "Capability.matches?",
           "Domain.Agent must NOT hand-roll Capability.matches? — route the match through " <>
             "Ezagent.Identity.caps_authorize?/2 (the chokepoint owner). The global p3 probe " <>
             "covers presentation surfaces, not the owner facade; SPEC §8.9."
  end
end
