defmodule Ezagent.Identity.OperatorReadsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity.OperatorReads

  describe "registry_all/1 (acceptance #5 — operator-gated global registry read)" do
    test "denies a non-operator caller (fail-closed)" do
      non_operator = Ezagent.URI.new!("entity://team-alpha/user/not-an-operator")

      assert {:error, :unauthorized} = OperatorReads.registry_all(non_operator)
    end

    test "denies a nil caller (fail-closed)" do
      assert {:error, :unauthorized} = OperatorReads.registry_all(nil)
    end

    test "an operator gets the global registry list" do
      uri_str =
        "session://team-alpha/default/operator-reads-#{System.unique_integer([:positive])}"

      :ok = Ezagent.KindRegistry.put_new(uri_str, self())

      assert {:ok, kinds} = OperatorReads.registry_all(Ezagent.Entity.User.admin_uri())

      assert Enum.any?(kinds, fn {uri, pid} -> uri == uri_str and pid == self() end)
    end

    # F5 (read-plane PR-4 rework): the gate is
    # `Ezagent.Identity.AdminAuthority.admin?/2` — the SAME operator
    # predicate the workspace-listing plane uses — NOT the exact
    # bootstrap-admin-URI equality of `Identity.admin?/1`. A promoted
    # system operator (whose authority comes from the system workspace,
    # not from being THE bootstrap admin) is accepted.
    test "F5: a PROMOTED (non-bootstrap) operator gets the full registry" do
      promoted =
        Ezagent.URI.new!("entity://system/user/promoted-#{System.unique_integer([:positive])}")

      # Discriminating guard: the OLD predicate (exact bootstrap-admin-URI
      # equality) rejects this caller — pre-fix they were locked out.
      refute Ezagent.Identity.admin?(promoted)

      uri_str =
        "session://team-alpha/default/promoted-op-#{System.unique_integer([:positive])}"

      :ok = Ezagent.KindRegistry.put_new(uri_str, self())

      assert {:ok, kinds} = OperatorReads.registry_all(promoted)
      assert Enum.any?(kinds, fn {uri, pid} -> uri == uri_str and pid == self() end)
    end

    # F5: an ordinary authenticated non-admin is REJECTED — and the
    # rejection is the propagated `{:error, :unauthorized}`, never a
    # coerced empty list that would be indistinguishable from "no rows".
    test "F5: an ordinary authenticated non-admin is rejected, not coerced to an empty list" do
      uri_str =
        "session://team-alpha/default/non-admin-reject-#{System.unique_integer([:positive])}"

      :ok = Ezagent.KindRegistry.put_new(uri_str, self())

      non_admin =
        Ezagent.URI.new!("entity://team-alpha/user/plain-#{System.unique_integer([:positive])}")

      assert {:error, :unauthorized} = OperatorReads.registry_all(non_admin)
    end
  end
end
