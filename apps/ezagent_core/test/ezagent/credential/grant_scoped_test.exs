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

  test "credential-materializer principal is ELIMINATED (north star) — authority is the per-grant GrantCap + agent self" do
    # System-principal elimination: the `credential-materializer` audit label is
    # removed from the Catalog. Credential source-read authority is the narrow
    # per-grant `GrantCap` cap (asserted above); api-key materialization runs under
    # the agent's own entity self-authority — no cataloged principal is involved.
    refute Ezagent.SystemPrincipal.Catalog.member?(
             Ezagent.URI.new!("system://credential-materializer")
           )
  end
end
