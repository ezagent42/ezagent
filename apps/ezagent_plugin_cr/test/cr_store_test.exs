defmodule EzagentPluginCr.CrStoreTest do
  use EzagentCore.DataCase, async: true

  alias EzagentPluginCr.CrStore

  # Use a unique tenant id per test to avoid cross-test state.
  defp tid, do: "t#{System.unique_integer([:positive])}"

  @actor "system://cr-store-test"

  # ---------------------------------------------------------------------------
  # ensure_active_cr
  # ---------------------------------------------------------------------------

  describe "ensure_active_cr/2" do
    test "creates a draft when no CR exists" do
      t = tid()
      assert {:ok, cr} = CrStore.ensure_active_cr(t, @actor)
      assert cr["status"] == "draft"
      assert cr["created_by"] == @actor
      assert cr["published_version"] == nil
      assert cr["notes"] == ""
      assert String.starts_with?(cr["cr_id"], "cr-")
      assert String.length(cr["cr_id"]) == 11
    end

    test "second call returns the SAME cr_id" do
      t = tid()
      {:ok, first} = CrStore.ensure_active_cr(t, @actor)
      {:ok, second} = CrStore.ensure_active_cr(t, @actor)
      assert first["cr_id"] == second["cr_id"]
    end
  end

  # ---------------------------------------------------------------------------
  # mark_published
  # ---------------------------------------------------------------------------

  describe "mark_published/3" do
    test "flips status to published and sets version" do
      t = tid()
      {:ok, cr} = CrStore.ensure_active_cr(t, @actor)
      assert :ok = CrStore.mark_published(t, cr["cr_id"], 1)

      {:ok, stored} = CrStore.get(t)
      assert stored["status"] == "published"
      assert stored["published_version"] == 1
    end

    test "wrong cr_id returns {:error, :cr_mismatch}" do
      t = tid()
      {:ok, _cr} = CrStore.ensure_active_cr(t, @actor)
      assert {:error, :cr_mismatch} = CrStore.mark_published(t, "cr-00000000", 1)
    end
  end

  # ---------------------------------------------------------------------------
  # ensure_active_cr after publish
  # ---------------------------------------------------------------------------

  describe "ensure_active_cr after publish" do
    test "returns a NEW cr_id after the previous CR is published" do
      t = tid()
      {:ok, first} = CrStore.ensure_active_cr(t, @actor)
      :ok = CrStore.mark_published(t, first["cr_id"], 1)

      {:ok, second} = CrStore.ensure_active_cr(t, @actor)
      assert second["cr_id"] != first["cr_id"]
      assert second["status"] == "draft"
    end
  end

  # ---------------------------------------------------------------------------
  # get
  # ---------------------------------------------------------------------------

  describe "get/1" do
    test "unknown tenant returns {:error, :not_found}" do
      assert {:error, :not_found} = CrStore.get("tenant-that-does-not-exist-#{tid()}")
    end
  end
end
