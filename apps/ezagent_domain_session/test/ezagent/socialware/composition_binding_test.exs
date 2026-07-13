defmodule Ezagent.Socialware.CompositionBindingTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Socialware.CompositionBinding

  test "active bindings preserve install/revision provenance and share one cap identity" do
    holder = agent_uri("holder")
    target = agent_uri("target")
    session_a = session_uri("a")
    session_b = session_uri("b")
    cap = operate_cap(target)

    assert {:ok, first} =
             CompositionBinding.upsert(binding_attrs(session_a, holder, target, cap, "install-a"))

    assert {:ok, second} =
             CompositionBinding.upsert(binding_attrs(session_b, holder, target, cap, "install-b"))

    assert first.id != second.id
    assert first.cap_identity == second.cap_identity
    assert first.definition_config_id == "definition-install-a"
    assert first.definition_content_hash == "hash-install-a"

    assert [binding_a, binding_b] = CompositionBinding.active_for_holder(holder)

    assert Enum.sort([binding_a.session_uri, binding_b.session_uri]) ==
             Enum.sort([URI.to_string(session_a), URI.to_string(session_b)])
  end

  test "deactivating one supporting binding keeps the shared identity active; last removes it" do
    holder = agent_uri("union-holder")
    target = agent_uri("union-target")
    session_a = session_uri("union-a")
    session_b = session_uri("union-b")
    cap = operate_cap(target)

    assert {:ok, _} =
             CompositionBinding.upsert(binding_attrs(session_a, holder, target, cap, "union-a"))

    assert {:ok, _} =
             CompositionBinding.upsert(binding_attrs(session_b, holder, target, cap, "union-b"))

    identity = CompositionBinding.cap_identity(cap)
    assert CompositionBinding.supported?(holder, identity)

    assert {:ok, [^holder]} = CompositionBinding.deactivate_session(session_a, :uninstall)
    assert CompositionBinding.supported?(holder, identity)

    assert {:ok, [^holder]} = CompositionBinding.deactivate_session(session_b, :uninstall)
    refute CompositionBinding.supported?(holder, identity)
  end

  test "deactivating a departed member invalidates source and target edges in that session" do
    source = agent_uri("source")
    target = agent_uri("departed")
    other_target = agent_uri("other")
    session = session_uri("departure")

    assert {:ok, _} =
             CompositionBinding.upsert(
               binding_attrs(session, source, target, operate_cap(target), "source-edge")
             )

    assert {:ok, _} =
             CompositionBinding.upsert(
               binding_attrs(
                 session,
                 target,
                 other_target,
                 operate_cap(other_target),
                 "target-edge"
               )
             )

    assert {:ok, holders} = CompositionBinding.deactivate_member(session, target, :role_departure)

    assert Enum.sort_by(holders, &URI.to_string/1) ==
             Enum.sort_by([source, target], &URI.to_string/1)

    assert CompositionBinding.active_for_holder(source) == []
    assert CompositionBinding.active_for_holder(target) == []
  end

  defp binding_attrs(session, source, target, cap, install_id) do
    %{
      session_uri: session,
      install_id: install_id,
      definition_config_id: "definition-#{install_id}",
      definition_content_hash: "hash-#{install_id}",
      source_role: "source",
      target_role: "target",
      source_uri: source,
      target_uri: target,
      workspace_uri: Ezagent.URI.workspace_of(source),
      behavior: cap.behavior,
      action: cap.action,
      issuer_uri: Ezagent.URI.new!("entity://composition/user/configurer"),
      cap: cap,
      status: :active
    }
  end

  defp operate_cap(target) do
    %Capability{
      Capability.cap(
        :agent,
        Ezagent.ActionSet.ApiKeys,
        :list_api_keys,
        Ezagent.URI.instance(target),
        Ezagent.URI.workspace_of(target)
      )
      | granted_by: Ezagent.URI.new!("entity://composition/user/configurer"),
        granted_at: DateTime.utc_now()
    }
  end

  defp agent_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/agent/#{name}-#{System.unique_integer([:positive])}")

  defp session_uri(name),
    do:
      Ezagent.URI.new!(
        "session://composition/socialware/#{name}-#{System.unique_integer([:positive])}"
      )
end
