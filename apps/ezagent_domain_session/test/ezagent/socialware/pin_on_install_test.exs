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
  defp attrs(name, bases, overrides) do
    %{
      name: name,
      title: "Pin #{name}",
      bases: bases,
      shape: [],
      visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
    }
    |> Map.merge(overrides)
  end

  defp write!(name, bases, overrides \\ %{}) do
    {:ok, definition} = Definition.new(attrs(name, bases, overrides))

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

  test "T-Pin-d: re-seeding an already-installed ref is idempotent, not a collision" do
    # Regression (feat/registry-p0): P0 added `definition_content_hash` to the
    # install body. The install `source_turn_id` is DETERMINISTIC
    # (`socialware-install:<session>:<ref>`), so the shared seed's
    # "same-turn + different-body → collision" guard misfired whenever a
    # re-seed's baked body differed from an already-installed pointer (a pre-P0
    # body, OR a body pinned to a newer revision) — even though the install
    # pointer id is per (session, ref) and can NEVER be a two-plugins-one-name
    # clash. Boot re-seeds the persisted `main` session on every start, so this
    # collided at boot and tore `main` down. Seeding an already-installed ref
    # must be an idempotent no-op that HOLDS the frozen revision (only `repoint`
    # advances a running install).
    name = "pin-d-#{uniq()}"
    session_uri = Ezagent.URI.session("team-pin", "generic", name)

    r1 = write!(name, [Ezagent.ActionSet.Session])
    {:ok, frozen_r1} = Installation.freeze_template_installs(%{installs: [name]}, @ws)

    :ok = Installation.install_template_installs(session_uri, @ws, frozen_r1, @actor)
    assert [%Definition{} = installed_r1] = Installation.installed_definitions(session_uri)
    refute Ezagent.ActionSet.Turn in Definition.behaviors(installed_r1)

    # a new revision publishes and a fresh freeze pins R2 — a re-seed's body now
    # bakes a DIFFERENT config_id under the SAME deterministic source_turn_id.
    r2 = write!(name, [Ezagent.ActionSet.Session, Ezagent.ActionSet.Turn])
    refute r2.id == r1.id
    {:ok, frozen_r2} = Installation.freeze_template_installs(%{installs: [name]}, @ws)

    # must NOT raise `{:socialware_install_collision, ...}` — idempotent no-op.
    assert :ok = Installation.install_template_installs(session_uri, @ws, frozen_r2, @actor)

    # freeze-pin held: the running install stays at R1 (seed never advances).
    assert [%Definition{} = still_r1] = Installation.installed_definitions(session_uri)
    refute Ezagent.ActionSet.Turn in Definition.behaviors(still_r1)
  end

  test "T-Pin-e: pin_installs_from_session re-pins raw content to the session's frozen record (repair path)" do
    name = "pin-e-#{uniq()}"
    session_uri = Ezagent.URI.session("team-pin", "generic", name)

    r1 = write!(name, [Ezagent.ActionSet.Session])
    {:ok, frozen} = Installation.freeze_template_installs(%{installs: [name]}, @ws)
    :ok = Installation.install_template_installs(session_uri, @ws, frozen, @actor)

    # publish R2 — the current pointer now advances to R2.
    r2 = write!(name, [Ezagent.ActionSet.Session, Ezagent.ActionSet.Turn])
    refute r2.id == r1.id

    # the raw (unpinned) template content the repair path re-reads.
    raw = %{installs: [name]}

    # CONTROL — raw content live-resolves to R2 (this is the pre-fix repair bug).
    {:ok, [{_d1, live_obj, _i1}]} = Installation.resolved_template_installs(raw, @ws)
    assert live_obj.id == r2.id

    # re-pinning from the session's install record recovers R1.
    pinned = Installation.pin_installs_from_session(session_uri, raw)
    {:ok, [{_d2, pinned_obj, _i2}]} = Installation.resolved_template_installs(pinned, @ws)
    assert pinned_obj.id == r1.id

    {:ok, behaviors} = Installation.behavior_set_for_template(pinned, @ws)
    refute Ezagent.ActionSet.Turn in behaviors
  end

  test "T-Pin-f: pin_installs_from_session leaves a never-installed ref unpinned (resolves live)" do
    name = "pin-f-#{uniq()}"
    session_uri = Ezagent.URI.session("team-pin", "generic", "#{name}-sess")
    r1 = write!(name, [Ezagent.ActionSet.Session])

    # no per-session install record exists for this session/ref — the ref keeps
    # its bare form and still resolves the current revision live.
    pinned = Installation.pin_installs_from_session(session_uri, %{installs: [name]})
    {:ok, [{_d, obj, _i}]} = Installation.resolved_template_installs(pinned, @ws)
    assert obj.id == r1.id
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

  test "T-Pin-g: freeze expands and pins transitive requires closure" do
    n = uniq()
    dep_name = "pin-g-dep-#{n}"
    app_name = "pin-g-app-#{n}"

    dep = write!(dep_name, [Ezagent.ActionSet.Session])
    app = write!(app_name, [Ezagent.ActionSet.Session], %{requires: [dep_name]})

    assert {:ok, frozen} = Installation.freeze_template_installs(%{installs: [app_name]}, @ws)

    refs_to_config_ids =
      frozen
      |> Map.fetch!(:installs)
      |> Map.new(&{&1.ref, &1.config_id})

    assert refs_to_config_ids == %{dep_name => dep.id, app_name => app.id}
  end
end
