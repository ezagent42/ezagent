defmodule EzagentWeb.RequestHostLinkTest do
  @moduledoc """
  Regression guard for the canary=nightly-container bug: magic-link,
  email-confirmation, and password-reset emails must build their URL from the
  **request host** (allowlisted), not the statically configured `Endpoint.url/0`.

  Runs `async: false` because it reads the process-global Swoosh Local mailbox.
  """
  use EzagentWeb.ConnCase, async: false

  alias Ezagent.{AppSettings, Users}
  alias Ezagent.Entity.Profile
  alias EzagentWeb.RateLimiter
  alias Swoosh.Adapters.Local.Storage.Memory

  @canary "canary.ezagent.chat"

  setup do
    Memory.delete_all()
    RateLimiter.reset_all()
    :ok
  end

  # Pull the delivered email whose link contains `path_fragment`.
  defp link_for(path_fragment) do
    email =
      Memory.all()
      |> Enum.find(fn e -> e.text_body =~ path_fragment end)

    assert email, "expected an email containing #{path_fragment}, got: #{inspect(Memory.all())}"

    [_, url] = Regex.run(~r{(https?://\S+#{Regex.escape(path_fragment)}\S*)}, email.text_body)
    url
  end

  defp on_host(conn, host), do: %{conn | host: host}

  describe "magic-link (POST /login/magic)" do
    setup do
      # `maybe_send_magic_link` gates on AppSettings.mail_configured?/0.
      AppSettings.put("smtp_config", %{
        "host" => "smtp.example.com",
        "port" => 587,
        "username" => "u",
        "password" => "p",
        "from_address" => "no-reply@ezagent.chat"
      })

      :ok
    end

    test "canary host produces a canary magic-link (not nightly)", %{conn: conn} do
      email = "mluser#{System.unique_integer([:positive])}@good.com"
      uri = "entity://team-alpha/user/ml#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])
      {:ok, _} = Profile.upsert(%{entity_uri: uri, display_name: "ML", email: email})

      conn
      |> on_host(@canary)
      |> Plug.Test.init_test_session(%{})
      |> post("/login/magic", %{"email" => email})

      assert link_for("/auth/magic/") =~ ~r{^https://canary\.ezagent\.chat/auth/magic/}
    end

    test "untrusted host falls back to the configured Endpoint host (injection guard)", %{
      conn: conn
    } do
      email = "mlevil#{System.unique_integer([:positive])}@good.com"
      uri = "entity://team-alpha/user/mle#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])
      {:ok, _} = Profile.upsert(%{entity_uri: uri, display_name: "MLE", email: email})

      conn
      |> on_host("evil.example.com")
      |> Plug.Test.init_test_session(%{})
      |> post("/login/magic", %{"email" => email})

      link = link_for("/auth/magic/")
      refute link =~ "evil.example.com"
      assert String.starts_with?(link, EzagentWeb.Endpoint.url() <> "/auth/magic/")
    end
  end

  describe "email confirmation (POST /register)" do
    setup do
      AppSettings.put("registration_open", true)
      :ok
    end

    test "canary host produces a canary confirm link", %{conn: conn} do
      email = "conf#{System.unique_integer([:positive])}@ex.com"

      conn
      |> on_host(@canary)
      |> post("/register", %{
        "email" => email,
        "password" => "secret123",
        "display_name" => "Conf"
      })

      assert link_for("/auth/confirm/") =~ ~r{^https://canary\.ezagent\.chat/auth/confirm/}
    end
  end

  describe "password reset (POST /auth/reset)" do
    test "canary host produces a canary reset link", %{conn: conn} do
      email = "rst#{System.unique_integer([:positive])}@ex.com"
      uri = "entity://team-alpha/user/rst#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "oldpassword", [])
      {:ok, _} = Profile.upsert(%{entity_uri: uri, display_name: "Rst", email: email})

      conn
      |> on_host(@canary)
      |> post("/auth/reset", %{"email" => email})

      assert link_for("/auth/reset/") =~ ~r{^https://canary\.ezagent\.chat/auth/reset/}
    end
  end
end
