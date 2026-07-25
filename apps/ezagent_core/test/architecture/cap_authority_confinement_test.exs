defmodule Ezagent.Architecture.CapAuthorityConfinementTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Test.OnChangeTestKind

  @core_lib Path.expand("../../lib", __DIR__)
  @allowed_secret_sites MapSet.new([
                          "ezagent/cap/authority.ex",
                          "ezagent/cap/verifier.ex",
                          "ezagent/cap/grant.ex",
                          "ezagent/ecto/kind_cap_authority.ex"
                        ])

  test "Kind authority key never enters slices or snapshots" do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_cap-authority-#{System.unique_integer([:positive])}"
      )

    assert {:ok, pid} = Ezagent.Kind.Server.start_link({OnChangeTestKind, %{uri: uri}})
    assert :ok = await_ready(uri)

    server_state = :sys.get_state(pid)
    private_key = server_state.authority.private_key

    assert is_binary(private_key)
    assert byte_size(private_key) > 0
    refute contains_binary?(server_state.state, private_key)

    assert {:ok, runtime_view} = Ezagent.Kind.runtime_view(pid)
    refute Map.has_key?(runtime_view, :authority)
    refute contains_binary?(runtime_view, private_key)

    assert {:ok, test_slice} = Ezagent.Kind.read(uri, :test, spawn: :never)
    refute contains_binary?(test_slice, private_key)

    assert %KindSnapshot{} = row = KindSnapshot.get(URI.to_string(uri))
    refute contains_binary?(row.state_binary, private_key)
    assert {:ok, persisted_state} = KindSnapshot.decode_state(row)
    refute contains_binary?(persisted_state, private_key)
  end

  test "raw signing and key material are confined to the three framework sites" do
    offenders =
      @core_lib
      |> source_files()
      |> Enum.reject(fn path -> MapSet.member?(@allowed_secret_sites, relative(path)) end)
      |> Enum.filter(fn path ->
        source = File.read!(path)

        Enum.any?(
          ["Signing.sign(", "Signing.verify(", "derive_keypair(", "private_key"],
          &String.contains?(source, &1)
        )
      end)
      |> Enum.map(&relative/1)

    assert offenders == [],
           "cap signing/key material escaped the three framework sites:\n" <>
             Enum.join(offenders, "\n")
  end

  test "cold verification selects only active public authority material" do
    source = File.read!(Path.join(@core_lib, "ezagent/ecto/kind_cap_authority.ex"))

    active_public =
      source
      |> String.split("def active_public(uri)")
      |> Enum.at(1)
      |> String.split("\n  @doc false")
      |> List.first()

    assert source =~ "def active_public(uri)"
    assert active_public =~ "generation: row.generation"
    assert active_public =~ "public_key: row.public_key"
    refute active_public =~ "key_id"
    refute active_public =~ "private_key"
    refute active_public =~ "active(uri)"
  end

  defp source_files(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  defp relative(path), do: Path.relative_to(path, @core_lib)

  defp contains_binary?(term, needle) when is_binary(term),
    do: :binary.match(term, needle) != :nomatch

  defp contains_binary?(term, needle),
    do: term |> :erlang.term_to_binary() |> contains_binary?(needle)

  defp await_ready(uri), do: await_ready(uri, System.monotonic_time(:millisecond) + 1_000)

  defp await_ready(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _status ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          await_ready(uri, deadline)
        end
    end
  end
end
