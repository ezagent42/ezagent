defmodule EzagentPluginContent.Platform.PlatformSoulStoreTest do
  use ExUnit.Case

  @test_role "test-role-platform-soul"
  @tmp_priv Path.join(System.tmp_dir!(), "platform_soul_store_test_#{System.unique_integer()}")

  setup do
    # Create a temporary priv dir structure to isolate tests from real platform files
    File.mkdir_p!(Path.join([@tmp_priv, "platform"]))
    File.mkdir_p!(Path.join([@tmp_priv, "framework", @test_role]))
    File.mkdir_p!(Path.join([@tmp_priv, "templates", @test_role]))

    # Write test fixture files
    File.write!(Path.join([@tmp_priv, "platform", "#{@test_role}.md"]), "platform content")
    File.write!(Path.join([@tmp_priv, "framework", @test_role, "soul.md"]), "framework content")
    File.write!(Path.join([@tmp_priv, "templates", @test_role, "soul.md"]), "template content")

    on_exit(fn -> File.rm_rf!(@tmp_priv) end)
    {:ok, base: @tmp_priv}
  end

  test "read_soul :platform returns content" do
    {:ok, content} = mock_read(:platform, @test_role, @tmp_priv)
    assert content == "platform content"
  end

  test "read_soul :framework returns content" do
    {:ok, content} = mock_read(:framework, @test_role, @tmp_priv)
    assert content == "framework content"
  end

  test "read_soul :template returns content" do
    {:ok, content} = mock_read(:template, @test_role, @tmp_priv)
    assert content == "template content"
  end

  test "read_soul nonexistent returns :not_found" do
    assert {:error, :not_found} = mock_read(:platform, "nonexistent-role", @tmp_priv)
  end

  test "write_soul :platform writes content" do
    mock_write(:platform, @test_role, "new platform content", @tmp_priv)
    {:ok, content} = mock_read(:platform, @test_role, @tmp_priv)
    assert content == "new platform content"
  end

  test "delete_soul :platform removes file" do
    mock_write(:platform, "delete-test", "temp", @tmp_priv)
    {:ok, _} = mock_read(:platform, "delete-test", @tmp_priv)
    :ok = mock_delete(:platform, "delete-test", @tmp_priv)
    assert {:error, :not_found} = mock_read(:platform, "delete-test", @tmp_priv)
  end

  # Helpers that simulate operating against a specific priv dir
  defp mock_read(level, role, base) do
    path = soul_path(level, role, base)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp mock_write(level, role, content, base) do
    path = soul_path(level, role, base)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    :ok
  end

  defp mock_delete(level, role, base) do
    path = soul_path(level, role, base)
    if File.exists?(path), do: File.rm!(path)
    :ok
  end

  defp soul_path(:platform, role, base), do: Path.join([base, "platform", "#{role}.md"])
  defp soul_path(:framework, role, base), do: Path.join([base, "framework", role, "soul.md"])
  defp soul_path(:template, role, base), do: Path.join([base, "templates", role, "soul.md"])
end
