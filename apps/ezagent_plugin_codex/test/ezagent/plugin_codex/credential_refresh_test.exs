defmodule EzagentPluginCodex.CredentialRefreshTest do
  @moduledoc """
  #21 PR-2b — codex test/E2E credential provisioner. Reproduces the FULL CODEX_HOME
  `credential_relpaths` set (`auth.json` + `config.toml`) from a durable source into
  an agent's CODEX_HOME. Unlike cc, codex's `auth.json` has no explicit `expiresAt`;
  it records `last_refresh` and the codex CLI self-refreshes the access token at
  runtime via the refresh token. So a *recent* source is copied as-is; only an
  implausibly-stale source (refresh token likely dead) triggers a refresh (injectable)
  or a clear error. The OAuth POST and clock are injected, so these tests NEVER hit
  the network or touch a real ~/.codex. The lock is crash-recoverable (stale lease
  is stolen).
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias EzagentPluginCodex.CredentialRefresh

  setup do
    base = Path.join(System.tmp_dir!(), "codex-credref-#{System.unique_integer([:positive])}")
    src = Path.join(base, "source")
    home = Path.join(base, "home")
    File.mkdir_p!(src)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, src: src, home: home}
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp write_auth(src, tokens, last_refresh_ms) do
    File.write!(
      Path.join(src, "auth.json"),
      Jason.encode!(%{"auth_mode" => "chatgpt", "last_refresh" => iso(last_refresh_ms), "tokens" => tokens})
    )
  end

  defp write_config(src, body \\ "model = \"gpt-5\"\n"), do: File.write!(Path.join(src, "config.toml"), body)
  defp read_auth(path), do: path |> File.read!() |> Jason.decode!()

  @day_ms 24 * 60 * 60 * 1000

  test "recent source is copied as-is (auth.json + config.toml), NO refresh, auth 0600",
       %{src: src, home: home} do
    now = 2_000_000_000_000
    write_auth(src, %{"access_token" => "AT", "refresh_token" => "RT", "id_token" => "ID", "account_id" => "ACC"}, now - 60_000)
    write_config(src)

    refute_called = fn _u, _ct, _b -> flunk("must not refresh a recent source") end

    assert :ok = CredentialRefresh.provision(src, home, now_ms: now, http_post: refute_called)

    assert read_auth(Path.join(home, "auth.json"))["tokens"]["access_token"] == "AT"
    assert File.read!(Path.join(home, "config.toml")) =~ "model"
    {:ok, %File.Stat{mode: m}} = File.stat(Path.join(home, "auth.json"))
    assert (m &&& 0o777) == 0o600
  end

  test "missing config.toml in source → clear error (the FULL set must be reproducible)",
       %{src: src, home: home} do
    now = 2_000_000_000_000
    write_auth(src, %{"access_token" => "AT", "refresh_token" => "RT"}, now)
    # no config.toml written

    assert {:error, {:source_missing_relpath, "config.toml"}} =
             CredentialRefresh.provision(src, home, now_ms: now, http_post: fn _, _, _ -> {:ok, 200, "{}"} end)
  end

  test "stale source + NO refresh hook → clear error (re-login needed)", %{src: src, home: home} do
    now = 2_000_000_000_000
    write_auth(src, %{"access_token" => "AT", "refresh_token" => "RT"}, now - 100 * @day_ms)
    write_config(src)

    assert {:error, :codex_source_stale} = CredentialRefresh.provision(src, home, now_ms: now)
  end

  test "stale source + refresh hook → refreshes, writes rotated tokens back, copies fresh",
       %{src: src, home: home} do
    now = 2_000_000_000_000
    write_auth(src, %{"access_token" => "old", "refresh_token" => "RT-old", "id_token" => "ID", "account_id" => "ACC"}, now - 100 * @day_ms)
    write_config(src)

    http_post = fn _url, "application/json", body ->
      assert Jason.decode!(body)["refresh_token"] == "RT-old"
      {:ok, 200, Jason.encode!(%{"access_token" => "AT-new", "refresh_token" => "RT-new", "id_token" => "ID2"})}
    end

    assert :ok = CredentialRefresh.provision(src, home, now_ms: now, http_post: http_post)

    src_tokens = read_auth(Path.join(src, "auth.json"))["tokens"]
    assert src_tokens["access_token"] == "AT-new"
    assert src_tokens["refresh_token"] == "RT-new"
    assert read_auth(Path.join(src, "auth.json"))["last_refresh"] == iso(now)
    assert read_auth(Path.join(home, "auth.json"))["tokens"]["access_token"] == "AT-new"
  end

  test "refresh HTTP failure → error, source NOT mutated", %{src: src, home: home} do
    now = 2_000_000_000_000
    write_auth(src, %{"access_token" => "old", "refresh_token" => "RT-old"}, now - 100 * @day_ms)
    write_config(src)

    http_post = fn _u, _ct, _b -> {:ok, 401, ~s({"error":"invalid_grant"})} end

    assert {:error, {:refresh_http_status, 401, _}} =
             CredentialRefresh.provision(src, home, now_ms: now, http_post: http_post)

    assert read_auth(Path.join(src, "auth.json"))["tokens"]["access_token"] == "old"
    refute File.exists?(Path.join(home, "auth.json"))
  end

  test "missing source dir → clear error", %{home: home} do
    assert {:error, {:source_not_found, _}} =
             CredentialRefresh.provision("/nope/codex-src", home, http_post: fn _, _, _ -> {:ok, 200, "{}"} end)
  end

  test "crash-safe lock: a stale lease (old mtime) is stolen, provision still succeeds",
       %{src: src, home: home} do
    now = 2_000_000_000_000
    write_auth(src, %{"access_token" => "AT", "refresh_token" => "RT"}, now)
    write_config(src)

    # simulate a crashed run's leftover lock with an ancient mtime
    lock = CredentialRefresh.lock_path(src)
    File.write!(lock, "dead-owner")
    File.touch!(lock, ~U[2000-01-01 00:00:00Z] |> DateTime.to_unix())

    assert :ok =
             CredentialRefresh.provision(src, home,
               now_ms: now,
               http_post: fn _, _, _ -> {:ok, 200, "{}"} end,
               lock_lease_ms: 1000
             )
  end
end
