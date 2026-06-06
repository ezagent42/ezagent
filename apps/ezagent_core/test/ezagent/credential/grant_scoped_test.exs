defmodule Ezagent.Credential.GrantCapTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.Credential.GrantCap

  test "derives a narrow read cap that MATCHES the real sandbox.read dispatch needed-cap" do
    source = Ezagent.URI.new!("entity://team-a/agent/alice-base")
    cap = GrantCap.read_cap_for(source)

    # scoped, not wildcard
    assert %Capability{action: :read, behavior: Ezagent.Behavior.Sandbox, kind: :agent} = cap
    assert cap.workspace_uri != :any and cap.instance != :any
    # instance is exactly the source; workspace is its workspace:// URI
    assert URI.to_string(cap.instance) == URI.to_string(source)
    assert URI.to_string(cap.workspace_uri) == URI.to_string(Capability.workspace_of(source))

    # The needed-cap the dispatch builds for `sandbox.read` on `source` — same
    # shape `Capability.cap_for_action/3` produces (kind/behavior/action/instance/
    # workspace_uri). Assert our derived cap satisfies it.
    needed = %{
      kind: :agent,
      behavior: Ezagent.Behavior.Sandbox,
      action: :read,
      instance: Ezagent.URI.instance(source),
      workspace_uri: Capability.workspace_of(source)
    }

    assert Capability.matches?(cap, needed)
  end

  test "the derived cap does NOT match a read on a DIFFERENT source (least-privilege)" do
    source = Ezagent.URI.new!("entity://team-a/agent/alice-base")
    other = Ezagent.URI.new!("entity://team-a/agent/bob-base")
    cap = GrantCap.read_cap_for(source)

    needed_other = %{
      kind: :agent,
      behavior: Ezagent.Behavior.Sandbox,
      action: :read,
      instance: Ezagent.URI.instance(other),
      workspace_uri: Capability.workspace_of(other)
    }

    refute Capability.matches?(cap, needed_other)
  end

  test "credential-materializer is a cataloged identity with no standing caps" do
    uri = Ezagent.URI.new!("system://credential-materializer")
    assert Ezagent.SystemPrincipal.Catalog.member?(uri)
    # audit identity only — holds NO standing caps (per-source authority is the
    # narrow derived cap above). caps_for!/1 must not raise.
    assert Ezagent.SystemPrincipal.Catalog.caps_for!(uri) == []
  end
end
