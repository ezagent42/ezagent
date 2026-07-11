defmodule Ezagent.Architecture.CapArchDependencyTest do
  @moduledoc """
  Dependency skeleton for the Phase 3 crypto seam.

  `Ezagent.Cap` must remain core-owned and must not reach upward into any
  `ezagent_domain_*` application. S2 extends this gate when the complete
  authorization algorithm moves beside the seam.
  """
  use ExUnit.Case, async: true

  test "Ezagent.Cap has no domain module or umbrella-app dependency" do
    root = repo_root()
    cap_source = File.read!(Path.join(root, "apps/ezagent_core/lib/ezagent/cap.ex"))
    core_mix = File.read!(Path.join(root, "apps/ezagent_core/mix.exs"))

    refute cap_source =~ "Ezagent.Identity"
    refute cap_source =~ "EzagentDomain"
    refute cap_source =~ "ezagent_domain_"
    refute core_mix =~ ~r/\{:ezagent_domain_[a-z_]+,\s*in_umbrella:/
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
