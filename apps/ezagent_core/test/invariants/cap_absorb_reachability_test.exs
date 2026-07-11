defmodule Ezagent.Invariants.CapAbsorbReachabilityTest do
  @moduledoc """
  S3 I2/I8 reachability gate: absorb is a VM-internal, same-node store action.
  It verifies an already-issued artifact and never issues authority itself.
  """
  use ExUnit.Case, async: true

  test "absorb is provenance-gated, verifies, and never self-issues" do
    source = identity_source()
    [_, absorb_section] = String.split(source, "def handle_absorb_cap", parts: 2)
    [absorb_section | _] = String.split(absorb_section, "def handle_revoke_cap", parts: 2)

    assert absorb_section =~ "%{caller: :vm_internal}"
    assert absorb_section =~ "Ezagent.Cap.verify(cap_struct)"
    assert absorb_section =~ "def handle_absorb_cap(_args, _ctx), do: {:error, :unauthorized}"
    refute absorb_section =~ "Cap.issue"
  end

  test "Phase 3 contains no cross-node absorb transport" do
    root = repo_root()

    violations =
      root
      |> Path.join("apps/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/test/"))
      |> Enum.filter(fn file ->
        source = File.read!(file)
        source =~ "absorb_cap" and (source =~ ":rpc." or source =~ "Node.connect")
      end)

    assert violations == []
  end

  defp identity_source do
    File.read!(
      Path.join(
        repo_root(),
        "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
      )
    )
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
