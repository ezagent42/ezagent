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
        "session://team-alpha/operator-reads-#{System.unique_integer([:positive])}"

      :ok = Ezagent.KindRegistry.put_new(uri_str, self())

      assert {:ok, kinds} = OperatorReads.registry_all(Ezagent.Entity.User.admin_uri())

      assert Enum.any?(kinds, fn {uri, pid} -> uri == uri_str and pid == self() end)
    end
  end
end
