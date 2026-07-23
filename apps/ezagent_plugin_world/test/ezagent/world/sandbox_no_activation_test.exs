defmodule Ezagent.World.SandboxNoActivationTest do
  @moduledoc """
  FP5 S5 (#115, codex MEDIUM-2) regression for the world agent-DETAIL surface's
  sandbox read.

  `Ezagent.World.IdentityData` rendered an agent's `config_dir` / `project_cwd` /
  `source_template` (and the extension list) by dispatching `:sandbox/:read`
  (`:call`), which lazy-spawns + force-activates a cold agent — a cold `cc` agent
  needs >5s to launch claude, blowing the ReadyGate budget → the detail page
  showed `:activate_timeout`. The fix reads the agent's sandbox state from the
  durable `:sandbox` slice via the OWNER's non-activating reader
  (`Ezagent.ActionSet.Sandbox.read_persisted_state/1` — live registry lookup
  first, then the persisted snapshot) WITHOUT activation, after preserving the
  `:sandbox/:read` cap gate via `Ezagent.Identity.caps_authorize?/2`.

  This test seeds a SNAPSHOT for a COLD agent (Kind never spawned) and asserts
  the sandbox fields render from the snapshot AND the agent is never activated,
  plus the caller gate still rejects an uncapped caller.

  Mirrors `Ezagent.World.IdentityCapsNoActivationTest` (the sibling caps panel
  fix in the same PR).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.SnapshotStore
  alias Ezagent.World.IdentityData

  setup do
    name = "sandbox-cold-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)

    config_dir = "/tmp/ez-cold-config/#{name}"
    project_cwd = "/work/#{name}"
    flavor = "cc"

    # Persist a snapshot whose `:sandbox` slice carries the state the `:read`
    # action would have returned — the COLD-path state the read must resolve.
    # NO Ezagent.Kind.spawn → the agent is cold. `respawn_template_data` is where
    # the detail page reads `project_cwd` + source-template `flavor` from.
    {:ok, _} =
      SnapshotStore.write(
        agent,
        %{
          sandbox: %{
            config_dir_path: config_dir,
            template_class: nil,
            respawn_template_data: %{project_cwd: project_cwd, flavor: flavor},
            pty_phase: nil
          }
        },
        kind_type: :agent
      )

    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent)),
           "precondition: agent must be cold (Kind not registered)"

    %{
      agent: agent,
      config_dir: config_dir,
      project_cwd: project_cwd,
      flavor: flavor
    }
  end

  defp agent_state(agent, caller_uri, caller_caps) do
    IdentityData.state_for(
      %{
        component: "agent_detail",
        title: "Agent",
        path: "/identities/agent_detail",
        entity_uri: agent
      },
      %{workspace_uri: nil, caller_uri: caller_uri, caller_caps: caller_caps}
    )
  end

  test "sandbox fields render from the snapshot WITHOUT activating the cold agent",
       %{agent: agent, config_dir: config_dir, project_cwd: project_cwd, flavor: flavor} do
    admin = Ezagent.URI.user(:system, :admin)
    admin_caps =
      MapSet.new([
        Ezagent.Test.CapHelper.signed_fixture_cap!(
          agent,
          :agent,
          Ezagent.ActionSet.Sandbox,
          :read,
          admin
        )
      ])

    state = agent_state(agent, admin, admin_caps)

    assert state["config_dir"] == config_dir
    assert state["project_cwd"] == project_cwd
    assert state["source_template"] == flavor

    # THE INVARIANT: rendering the detail page (incl. the sandbox read) did NOT
    # start the agent Kind. config/caps reads were already snapshot-based in this
    # PR; the sandbox read was the remaining activator (codex MEDIUM-2).
    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent)),
           "the agent-detail sandbox read activated the agent — it must snapshot-read, not dispatch"
  end

  test "the OWNER reader resolves the cold sandbox state directly without activation",
       %{agent: agent, config_dir: config_dir} do
    state = Ezagent.ActionSet.Sandbox.read_persisted_state(agent)

    assert is_map(state)
    assert state.config_dir_path == config_dir
    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent))
  end

  test "a caller capped for a DIFFERENT agent is rejected (instance-scoped gate), without activating",
       %{agent: agent} do
    # A real `:sandbox/:read` cap, traceable to a real entity, but bound to
    # ANOTHER agent's instance. The gate must NOT authorize reading THIS agent —
    # proving the needed-cap carries the target instance (not `:any`); a widened
    # gate (instance omitted/`:any`) would WRONGLY render the fields.
    other_agent = Ezagent.URI.entity(:team_alpha, :agent, "other-#{System.unique_integer([:positive])}")
    granter = Ezagent.URI.user(:system, :admin)

    wrong_cap =
      Ezagent.Test.CapHelper.signed_fixture_cap!(
        other_agent,
        :agent,
        Ezagent.ActionSet.Sandbox,
        :read,
        granter
      )

    state = agent_state(agent, granter, MapSet.new([wrong_cap]))

    assert state["config_dir"] == nil,
           "a cap bound to a different agent must NOT authorize this agent's sandbox read"

    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent))
  end

  test "a caller capped for THIS agent's instance is authorized (positive narrow-cap)",
       %{agent: agent, config_dir: config_dir} do
    granter = Ezagent.URI.user(:system, :admin)

    right_cap =
      Ezagent.Test.CapHelper.signed_fixture_cap!(
        agent,
        :agent,
        Ezagent.ActionSet.Sandbox,
        :read,
        granter
      )

    state = agent_state(agent, granter, MapSet.new([right_cap]))

    assert state["config_dir"] == config_dir
    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent))
  end

  test "an uncapped caller is rejected, degrading sandbox fields to nil, without activating",
       %{agent: agent} do
    # No caps → the `:sandbox/:read` gate denies; sandbox_read returns
    # {:error, :unauthorized}; agent_sandbox_state degrades to nil; the detail
    # fields render nil. The page does NOT error out, and never activates.
    state = agent_state(agent, nil, MapSet.new())

    assert state["config_dir"] == nil
    assert state["project_cwd"] == nil
    assert state["source_template"] == nil

    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent)),
           "an unauthorized sandbox read still must not activate the agent"
  end
end
