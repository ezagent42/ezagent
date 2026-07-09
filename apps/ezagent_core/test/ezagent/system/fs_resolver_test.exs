defmodule Ezagent.System.FsResolverTest do
  @moduledoc """
  Tests for the `system://<type>[/<name>]` filesystem resolution seam
  (Resource-unification P3 / SPEC §10 OI-3).

  Unlike the tenant `resource://` resolver, system artifacts are node-global —
  there is NO `<ws>` and NO per-caller authority axis: a system artifact (global
  app cred, plugin config, diagnostic log) belongs to the deployment, not to a
  tenant. The seam therefore maps a CLOSED `<type>` allowlist to a sanctioned
  `Ezagent.Home` component, with the SAME hardening as the resource resolver
  (`.`/`..`/separator/NUL rejection before any `Path.join`, closed allowlist,
  single Home chokepoint).
  """
  use ExUnit.Case, async: true

  alias Ezagent.System.FsResolver
  alias Ezagent.URI, as: EzURI

  describe "R-1 — closed allowlist (no implicit Home catch-all)" do
    test "an unregistered system <type> returns :none" do
      uri = EzURI.system_principal("definitely-not-a-system-type")
      assert FsResolver.resolve(uri) == :none
    end

    test "a non-system URI is :none (not ours)" do
      uri = EzURI.resource("acme", "uploads", "x")
      assert FsResolver.resolve(uri) == :none
    end
  end

  describe "R-2 — unsafe-segment rejection before any Path.join" do
    test "a name of '..' is rejected" do
      uri = EzURI.system("credentials", "..")
      assert {:error, {:unsafe_segment, ".."}} = FsResolver.resolve(uri)
    end

    test "a name containing a NUL is rejected" do
      # build past segment! by hand — segment! permits NUL, the resolver must not.
      uri = %URI{EzURI.system("credentials", "ok") | path: "/a" <> <<0>> <> "b"}
      assert {:error, {:unsafe_segment, _}} = FsResolver.resolve(uri)
    end
  end

  describe "R-4 — Home is the backend, byte-identical to the legacy path" do
    test "system://credentials/<name> resolves under the credentials component" do
      uri = EzURI.system("credentials", "feishu.yaml")
      assert {:ok, path} = FsResolver.resolve(uri)
      assert path == Path.join(Ezagent.Home.path(:credentials), "feishu.yaml")
    end

    test "a single-segment system://<type> resolves to the component dir" do
      uri = EzURI.system_principal("logs")
      assert {:ok, path} = FsResolver.resolve(uri)
      assert path == Ezagent.Home.path(:logs)
    end

    test "system://inbox/<name> resolves under the profile inbox component" do
      uri = EzURI.system("inbox", "x.bin")
      assert {:ok, path} = FsResolver.resolve(uri)
      assert path == Path.join(Ezagent.Home.path("inbox"), "x.bin")
    end

    test "system://plugins/<name> resolves under the plugins component" do
      uri = EzURI.system("plugins", "feishu-bindings.yaml")
      assert {:ok, path} = FsResolver.resolve(uri)
      assert path == Path.join(Ezagent.Home.path(:plugins), "feishu-bindings.yaml")
    end

    test "system://socialware resolves to the deployment socialware seed dir" do
      uri = EzURI.system_principal("socialware")
      assert {:ok, path} = FsResolver.resolve(uri)
      assert path == Ezagent.Home.path("socialware")
    end

    test "system://skills resolves to the deployment skill seed dir" do
      uri = EzURI.system_principal("skills")
      assert {:ok, path} = FsResolver.resolve(uri)
      assert path == Ezagent.Home.path("skills")
    end
  end

  describe "UriQuery seam" do
    test "resolves through Ezagent.UriQuery via the :system_path attr" do
      :ok = FsResolver.register()
      uri = EzURI.system("credentials", "feishu.yaml")

      assert {:ok, path} = Ezagent.UriQuery.resolve(FsResolver.attr(), uri)
      assert path == Path.join(Ezagent.Home.path(:credentials), "feishu.yaml")
    end

    test "path!/1 raises for a non-system / unregistered type" do
      assert_raise ArgumentError, fn ->
        FsResolver.path!(EzURI.system_principal("nope"))
      end
    end

    test "path!/1 returns the resolved path for a registered type" do
      assert FsResolver.path!(EzURI.system("credentials", "smtp_config.json")) ==
               Path.join(Ezagent.Home.path(:credentials), "smtp_config.json")
    end
  end

  describe "read_yaml/1 — seam-backed credential read (codex P3 HIGH)" do
    # Writes to the seam-resolved path under the active EZAGENT_HOME using a
    # unique throwaway artifact name (no env mutation → safe under async: true),
    # and removes it after.
    test "reads + parses a YAML system artifact through the seam" do
      uri = EzURI.system("credentials", "p3-read-yaml-#{System.unique_integer([:positive])}.yaml")
      path = FsResolver.path!(uri)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "app_id: cli_x\napp_secret: s\n")
      on_exit(fn -> File.rm_rf(path) end)

      assert {:ok, %{"app_id" => "cli_x", "app_secret" => "s"}} = FsResolver.read_yaml(uri)
    end

    test "a missing artifact returns {:error, :not_found}" do
      uri = EzURI.system("credentials", "p3-absent-#{System.unique_integer([:positive])}.yaml")
      assert FsResolver.read_yaml(uri) == {:error, :not_found}
    end
  end
end
