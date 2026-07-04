defmodule Ezagent.Socialware.PinOnInstallTest do
  # SPEC §4 / §8.2 — freeze-pin: an install binds to the revision CURRENT at
  # create time (frozen into the session's local template content), so a later
  # publish does NOT change what an already-created session resolves. The explicit
  # `repoint` primitive is the sole forward-advance.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}

  @ws Ezagent.URI.new!("workspace://team-pin")
  @actor Ezagent.URI.new!("entity://team-pin/user/alice")

  defp uniq, do: System.unique_integer([:positive])

  # bases decide the resolved behavior set — R1 (Session only) vs R2 (Session +
  # Turn) so the two revisions are behaviorally distinguishable.
  defp attrs(name, bases) do
    %{
      name: name,
      title: "Pin #{name}",
      bases: bases,
      shape: [],
      visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
    }
  end

  defp write!(name, bases) do
    {:ok, definition} = Definition.new(attrs(name, bases))

    {:ok, object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @ws,
        caller_workspace_uri: @ws,
        actor_uri: @actor
      )

    object
  end

  test "T-Pin-a: a running install stays frozen to R1 while live resolution follows R2" do
    name = "pin-a-#{uniq()}"
    r1 = write!(name, [Ezagent.ActionSet.Session])

    # freeze at create time — bakes R1's config_id into the content's installs
    {:ok, frozen} = Installation.freeze_template_installs(%{installs: [name]}, @ws)

    # publish a NEW revision R2 with an extra behavior (Turn)
    r2 = write!(name, [Ezagent.ActionSet.Session, Ezagent.ActionSet.Turn])
    refute r2.id == r1.id

    # the frozen content resolves the EXACT R1 revision (not the current pointer)
    {:ok, [{_def, object, _install}]} = Installation.resolved_template_installs(frozen, @ws)
    assert object.id == r1.id

    # ...and its behavior set is built from R1 (no Turn)
    {:ok, frozen_behaviors} = Installation.behavior_set_for_template(frozen, @ws)
    refute Ezagent.ActionSet.Turn in frozen_behaviors

    # CONTROL — an UNFROZEN `installs: [ref]` live-resolves the current pointer R2
    # (Turn present). This contrast is what proves the freeze, since the install
    # record was already pinned before this phase.
    {:ok, live_behaviors} = Installation.behavior_set_for_template(%{installs: [name]}, @ws)
    assert Ezagent.ActionSet.Turn in live_behaviors
  end

  test "T-Pin-b: explicit repoint advances a pinned install to R2" do
    name = "pin-b-#{uniq()}"
    session_uri = Ezagent.URI.session("team-pin", "generic", name)

    r1 = write!(name, [Ezagent.ActionSet.Session])
    {:ok, frozen} = Installation.freeze_template_installs(%{installs: [name]}, @ws)

    # install record pinned to R1
    :ok = Installation.install_template_installs(session_uri, @ws, frozen, @actor)
    assert [%Definition{} = installed_r1] = Installation.installed_definitions(session_uri)
    refute Ezagent.ActionSet.Turn in Definition.behaviors(installed_r1)

    # publish R2, then explicitly repoint — the sole forward-advance path
    r2 = write!(name, [Ezagent.ActionSet.Session, Ezagent.ActionSet.Turn])
    refute r2.id == r1.id
    :ok = Installation.repoint_template_installs(session_uri, @ws, frozen, @actor)

    assert [%Definition{} = installed_r2] = Installation.installed_definitions(session_uri)
    assert Ezagent.ActionSet.Turn in Definition.behaviors(installed_r2)

    # a fresh freeze now pins R2, so the next spawn builds from R2
    {:ok, refrozen} = Installation.freeze_template_installs(%{installs: [name]}, @ws)
    {:ok, behaviors} = Installation.behavior_set_for_template(refrozen, @ws)
    assert Ezagent.ActionSet.Turn in behaviors
  end

  test "T-Pin-c: a fresh install records the resolved revision id + content_hash" do
    name = "pin-c-#{uniq()}"
    r1 = write!(name, [Ezagent.ActionSet.Session])

    {:ok, frozen} = Installation.freeze_template_installs(%{installs: [name]}, @ws)
    [spec] = Map.fetch!(frozen, :installs)

    assert spec.config_id == r1.id
    assert spec.content_hash == r1.content_hash
    assert is_binary(spec.content_hash)
  end
end
