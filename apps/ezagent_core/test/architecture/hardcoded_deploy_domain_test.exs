Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.HardcodedDeployDomainTest do
  @moduledoc """
  Deployment host literals belong in config, not production lib code.

  This locks out the operator-console regression where the router baked the
  `world.` host scope, and the related drift where app/world deploy hosts are
  copied into libraries instead of flowing through runtime config.
  """
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

  test "no hardcoded app/world deploy host literals in lib code" do
    assert_zero(:hardcoded_deploy_domain_hosts)
  end

  describe "hardcoded deploy-domain fixtures" do
    test "POSITIVE: literal world host scope is flagged" do
      source = """
      defmodule Demo.Router do
        scope "/", DemoWorld, host: "world." do
          live "/admin", WorldLive
        end
      end
      """

      assert Scan.count_hardcoded_deploy_domain_hosts_in_source(source) == 1
    end

    test "POSITIVE: literal app deploy host default is flagged" do
      source = """
      defmodule Demo.Url do
        def host, do: System.get_env("EZAGENT_PUBLIC_HOST", "app.ezagent.chat")
      end
      """

      assert Scan.count_hardcoded_deploy_domain_hosts_in_source(source) == 1
    end

    test "POSITIVE: literal world deploy URL is flagged" do
      source = """
      defmodule Demo.Url do
        def url, do: "https://world.ezagent.chat/admin"
      end
      """

      assert Scan.count_hardcoded_deploy_domain_hosts_in_source(source) == 1
    end

    test "NEGATIVE: ezagent.chat email addresses are not deploy hosts" do
      source = """
      defmodule Demo.Email do
        @from "no-reply@ezagent.chat"
        def from, do: @from
      end
      """

      assert Scan.count_hardcoded_deploy_domain_hosts_in_source(source) == 0
    end

    test "`# arch-allow:` suppresses a justified literal" do
      source = """
      defmodule Demo.Legacy do
        def url, do: "https://app.ezagent.chat" # arch-allow: fixture legacy URL
      end
      """

      assert Scan.count_hardcoded_deploy_domain_hosts_in_source(source) == 0
    end
  end
end
