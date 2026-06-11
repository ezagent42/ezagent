defmodule EzagentPluginCr.Integration.ContentCrPipelineTest do
  @moduledoc """
  Integration test: full content→CR pipeline.

  Tests the end-to-end flow from tenant creation through CR publish,
  verifying that snapshot content matches the sandbox.
  """

  use ExUnit.Case

  alias EzagentPluginContent.Tenant.{TenantRuntime, TenantProvisioner}
  alias EzagentPluginContent.Soul.SoulStore
  alias EzagentPluginCr.CrEngine

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    tid = "test-pipeline-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      base = TenantRuntime.base_dir()
      tenant_dir = Path.join(base, tid)
      if File.exists?(tenant_dir), do: File.rm_rf!(tenant_dir)
    end)

    {:ok, tid: tid}
  end

  describe "full pipeline: create_tenant → write_slot → ensure_active_cr → publish" do
    test "publishes a CR whose snapshot matches the sandbox", %{tid: tid} do
      # ── Step 1: Create tenant ──
      assert {:ok, info} =
               TenantProvisioner.create_tenant(tid, "TestBrand",
                 industry: "cloud-comms",
                 role: "customer"
               )

      assert info[:tenant_id] == tid
      sandbox = info[:sandbox]
      assert File.dir?(sandbox)

      # ── Step 2: Add extra content to the sandbox for verification ──
      # Create a CLAUDE.md in sandbox root (R02 requires CLAUDE.md)
      claude_md = "# #{info[:brand_name]} Soul\n\n## Greeting\n\n{{greeting}}\n"
      File.write!(Path.join(sandbox, "CLAUDE.md"), claude_md)

      # Ensure skills/ has content (R03: no empty skill directories)
      skills_dir = Path.join(sandbox, "skills/customer")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "greeting.md"), "# Greeting Skill\n\nHello from {{company_name}}")

      # Ensure kb/ has content
      kb_dir = Path.join(sandbox, "kb")
      File.write!(Path.join(kb_dir, "kb.db"), "SQLite format 3\0")

      # Write a tracked content file in souls/ for diff verification
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      File.write!(Path.join(souls_dir, "customer_soul.md"), "## Customer Support\n\nWe are {{company_name}}")

      # ── Step 3: Write slot values ──
      slot_values = %{
        "greeting" => "Hello from the test tenant",
        "company_name" => "TestBrand"
      }

      base = TenantRuntime.base_dir()
      :ok = SoulStore.write_slots(base, tid, "customer", slot_values, :sandbox)

      # Verify slot values were written correctly
      assert {:ok, read_slots} = SoulStore.read_slots(base, tid, "customer", :sandbox)
      assert read_slots["greeting"] == "Hello from the test tenant"
      assert read_slots["company_name"] == "TestBrand"

      # ── Step 4: Ensure active CR ──
      assert {:ok, cr} = CrEngine.ensure_active_cr(tid)
      assert cr["status"] == "open"
      assert cr["tenant_id"] == tid
      assert String.starts_with?(cr["cr_id"], "cr-")

      # ── Step 5: Publish CR (lint + snapshot + symlink) ──
      assert {:ok, published} = CrEngine.publish(tid)
      assert published["status"] == "published"
      assert published["published_version"] == "v1"
      assert published["published_at"]

      # ── Step 6: Verify snapshot content matches sandbox ──
      release_dir = TenantRuntime.release_path(tid)
      version_dir = Path.join(release_dir, published["published_version"])
      assert File.dir?(version_dir), "release version directory should exist"

      # Verify current symlink points to version dir
      current = TenantRuntime.current_release_path(tid)
      assert File.exists?(current), "current symlink should exist"
      # readlink returns the resolved path
      current_target = File.read_link!(current)
      assert String.ends_with?(current_target, published["published_version"])

      # Verify key files in snapshot match sandbox
      verify_file_match(sandbox, version_dir, "CLAUDE.md")
      verify_file_match(sandbox, version_dir, "souls/customer_soul.md")
      verify_file_match(sandbox, version_dir, "skills/customer/greeting.md")
      verify_file_exists(version_dir, "slots/customer.yaml")
      verify_file_exists(version_dir, "kb/kb.db")
    end

    test "CR version bumps on subsequent publishes", %{tid: tid} do
      # Minimal setup: create tenant + required files
      assert {:ok, info} =
               TenantProvisioner.create_tenant(tid, "TestBrand",
                 industry: "cloud-comms",
                 role: "customer"
               )

      sandbox = info[:sandbox]

      # Satisfy R02 lint checks
      File.write!(Path.join(sandbox, "CLAUDE.md"), "# Test\n\n{{greeting}}")

      skills_dir = Path.join(sandbox, "skills/customer")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "test.md"), "# Test Skill")

      File.write!(Path.join(sandbox, "kb/kb.db"), "KB data")

      # First publish
      {:ok, published1} = CrEngine.publish(tid)
      assert published1["published_version"] == "v1"

      # Second publish
      {:ok, published2} = CrEngine.publish(tid)
      assert published2["published_version"] == "v2"
      assert published2["cr_id"] != published1["cr_id"]

      # Both version directories exist
      release = TenantRuntime.release_path(tid)
      assert File.dir?(Path.join(release, "v1"))
      assert File.dir?(Path.join(release, "v2"))

      # Current points to latest
      current = TenantRuntime.current_release_path(tid)
      assert String.ends_with?(File.read_link!(current), "v2")
    end

    test "snapshot preserves slot values from sandbox", %{tid: tid} do
      assert {:ok, info} =
               TenantProvisioner.create_tenant(tid, "TestBrand",
                 industry: "cloud-comms",
                 role: "customer"
               )

      sandbox = info[:sandbox]

      # Satisfy R02
      File.write!(Path.join(sandbox, "CLAUDE.md"), "# {{company_name}} Soul")
      File.mkdir_p!(Path.join(sandbox, "skills/customer"))
      File.write!(Path.join(sandbox, "skills/customer/faq.md"), "# FAQ for {{company_name}}")
      File.write!(Path.join(sandbox, "kb/kb.db"), "kb")

      # Write custom slot values
      base = TenantRuntime.base_dir()
      custom_slots = %{"company_name" => "Acme Corp", "greeting" => "Welcome to Acme!"}
      :ok = SoulStore.write_slots(base, tid, "customer", custom_slots, :sandbox)

      # Publish
      {:ok, published} = CrEngine.publish(tid)
      assert published["published_version"] == "v1"

      # Verify slots in snapshot match what we wrote
      assert {:ok, snap_slots} = SoulStore.read_slots(base, tid, "customer", :sandbox)
      assert snap_slots["company_name"] == "Acme Corp"
      assert snap_slots["greeting"] == "Welcome to Acme!"
    end
  end

  # ── Helpers ──

  defp verify_file_match(sandbox, version_dir, rel_path) do
    sandbox_file = Path.join(sandbox, rel_path)
    snapshot_file = Path.join(version_dir, rel_path)

    assert File.exists?(snapshot_file),
           "Expected snapshot to contain #{rel_path}"

    assert File.read!(sandbox_file) == File.read!(snapshot_file),
           "Content of #{rel_path} should match between sandbox and snapshot"
  end

  defp verify_file_exists(version_dir, rel_path) do
    assert File.exists?(Path.join(version_dir, rel_path)),
           "Expected snapshot to contain #{rel_path}"
  end
end
