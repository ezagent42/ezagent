defmodule EzagentPluginCc.CredentialRefreshTest do
  @moduledoc """
  #17 PR-E — test/E2E credential provisioning: refresh-if-expired (single-use token →
  atomic write-back to keep the source valid) + copy into the agent home. The OAuth POST
  and the clock are injected, so these tests NEVER hit the network or touch a real ~/.claude.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias EzagentPluginCc.CredentialRefresh

  setup do
    base = Path.join(System.tmp_dir!(), "cc-credref-#{System.unique_integer([:positive])}")
    src = Path.join(base, "source")
    home = Path.join(base, "home")
    File.mkdir_p!(src)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, src_path: Path.join(src, ".credentials.json"), home: home}
  end

  defp write_cred(path, oauth), do: File.write!(path, Jason.encode!(%{"claudeAiOauth" => oauth}))
  defp read_oauth(path), do: path |> File.read!() |> Jason.decode!() |> Map.fetch!("claudeAiOauth")

  test "non-expired source is copied as-is, NO refresh, source untouched", %{src_path: src, home: home} do
    now = 1_000_000
    write_cred(src, %{"accessToken" => "AT-valid", "refreshToken" => "RT1", "expiresAt" => now + 3_600_000})

    refute_called = fn _u, _ct, _b -> flunk("must not refresh a valid token") end

    assert :ok = CredentialRefresh.provision(src, home, now_ms: now, http_post: refute_called)

    assert read_oauth(Path.join(home, ".credentials.json"))["accessToken"] == "AT-valid"
    assert read_oauth(src)["accessToken"] == "AT-valid"
    {:ok, %File.Stat{mode: m}} = File.stat(Path.join(home, ".credentials.json"))
    assert (m &&& 0o777) == 0o600
  end

  test "expired source refreshes, writes the rotated token BACK to source, copies fresh to home",
       %{src_path: src, home: home} do
    now = 2_000_000
    write_cred(src, %{"accessToken" => "AT-old", "refreshToken" => "RT-old", "expiresAt" => now - 1})

    http_post = fn _url, "application/json", body ->
      decoded = Jason.decode!(body)
      assert decoded["grant_type"] == "refresh_token"
      assert decoded["refresh_token"] == "RT-old"
      {:ok, 200, Jason.encode!(%{"access_token" => "AT-new", "refresh_token" => "RT-new", "expires_in" => 3600})}
    end

    assert :ok = CredentialRefresh.provision(src, home, now_ms: now, http_post: http_post)

    # source rotated + written back (stays valid for next run)
    src_oauth = read_oauth(src)
    assert src_oauth["accessToken"] == "AT-new"
    assert src_oauth["refreshToken"] == "RT-new"
    assert src_oauth["expiresAt"] == now + 3_600_000
    # home got the fresh token
    assert read_oauth(Path.join(home, ".credentials.json"))["accessToken"] == "AT-new"
  end

  test "refresh HTTP failure → error, source NOT mutated", %{src_path: src, home: home} do
    now = 3_000_000
    write_cred(src, %{"accessToken" => "AT-old", "refreshToken" => "RT-old", "expiresAt" => now - 1})

    http_post = fn _url, _ct, _b -> {:ok, 401, ~s({"error":"invalid_grant"})} end

    assert {:error, {:refresh_http_status, 401, _}} =
             CredentialRefresh.provision(src, home, now_ms: now, http_post: http_post)

    # source left intact (old token), home not written
    assert read_oauth(src)["accessToken"] == "AT-old"
    refute File.exists?(Path.join(home, ".credentials.json"))
  end

  test "expired but no refreshToken → clear error", %{src_path: src, home: home} do
    now = 4_000_000
    write_cred(src, %{"accessToken" => "AT-old", "expiresAt" => now - 1})

    assert {:error, :source_missing_refresh_token} =
             CredentialRefresh.provision(src, home, now_ms: now, http_post: fn _, _, _ -> {:ok, 200, "{}"} end)
  end

  test "missing source file → clear error", %{home: home} do
    assert {:error, {:source_not_found, _}} =
             CredentialRefresh.provision("/nope/.credentials.json", home, http_post: fn _, _, _ -> {:ok, 200, "{}"} end)
  end
end
