Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.NoHardcodedSeedPrincipalTest do
  @moduledoc """
  no_hardcoded_seed_principal (2026-07-24, Allen) — socialware & seed
  provisioning must create a user/workspace (or grant ownership) using an
  EXISTING env-provided user identity, NEVER a principal baked into source.

  This AST gate flags a user/workspace-CREATE or owner-GRANT chokepoint call
  (`Users.create` / `Workspace.create` / `create_user` / `create_workspace` /
  `founder_join` / `grant_owner`) whose arguments carry a HARDCODED principal:

    * a string literal that is a principal URI (`entity://…` / `user://…`) or an
      email address,
    * `_.admin_uri()` — the genesis-admin accessor, or
    * an inline `Ezagent.URI.user(:system, :admin)` construction (both args
      compile-time literals).

  The env/runtime-resolved GOOD pattern (`%{created_by: founder_uri}` or
  `Ezagent.URI.user(workspace, slug)` — the identity args are VARS) is NOT
  flagged: that discriminator is the whole point of the gate.

  Two halves (mirrors `resource_kind_as_genserver` / `hardcoded_deploy_domain`):

    * the ratchet assertion over the real lib tree (`assert_at_or_below`), and
    * positive + negative AST fixtures proving the predicate separates
      hardcoded from env/runtime-resolved principals.

  Baseline is GRANDFATHERED at 1 — the sole current hit is the hello
  `CredentialBridge` DeepSeek deploy-key bridge, which #1557 deletes; see the
  manifest ledger. The genesis system-workspace bootstrap is `# arch-allow:`ed
  at its call site.
  """
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

  test "no NEW hardcoded principal in a seed/socialware provisioning create/grant" do
    assert_at_or_below(:no_hardcoded_seed_principal)
  end

  describe "AST predicate fixtures" do
    test "POSITIVE: a workspace-create with a hardcoded admin_uri() owner is flagged" do
      source = """
      defmodule Demo.Seed do
        def run do
          Ezagent.Workspace.create(home, %{created_by: User.admin_uri()})
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 1
    end

    test "POSITIVE: a user-create with a literal principal URI is flagged" do
      source = """
      defmodule Demo.Seed do
        def run do
          Ezagent.Users.create("entity://system/user/founder", nil, [])
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 1
    end

    test "POSITIVE: an inline URI.user(:system, :admin) construction in a create is flagged" do
      source = """
      defmodule Demo.Seed do
        def run do
          Ezagent.Workspace.create(ws, %{created_by: Ezagent.URI.user(:system, :admin)})
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 1
    end

    test "POSITIVE: a grant_owner with a literal email is flagged" do
      source = """
      defmodule Demo.Seed do
        def run do
          Ezagent.Workspace.grant_owner(ws, "founder@example.com")
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 1
    end

    test "NEGATIVE: a runtime-resolved founder_uri VAR owner is NOT flagged" do
      source = """
      defmodule Demo.Seed do
        def run(founder_uri) do
          Ezagent.Workspace.create(ws_name, %{created_by: founder_uri})
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 0
    end

    test "NEGATIVE: a URI.user(workspace, slug) built from VAR args is NOT flagged" do
      source = """
      defmodule Demo.Seed do
        def run(workspace, slug) do
          Ezagent.Users.create(Ezagent.URI.user(workspace, slug), nil, [])
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 0
    end

    test "NEGATIVE: a non-create call using admin_uri() (read/turn-drive) is NOT flagged" do
      source = """
      defmodule Demo.Seed do
        def run(session_uri, body) do
          TurnDriver.drive(session_uri, body, "seed", User.admin_uri())
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 0
    end

    test "NEGATIVE: a workspace-create with only a literal workspace NAME is NOT flagged" do
      source = """
      defmodule Demo.Seed do
        def run do
          Ezagent.Workspace.create("system", %{})
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 0
    end

    test "`# arch-allow:` suppresses a flagged create site" do
      source = """
      defmodule Demo.Seed do
        def run do
          Ezagent.Workspace.create("system", %{created_by: User.admin_uri()}) # arch-allow: genesis bootstrap
        end
      end
      """

      assert Scan.count_hardcoded_seed_principal_in_source(source) == 0
    end
  end
end
