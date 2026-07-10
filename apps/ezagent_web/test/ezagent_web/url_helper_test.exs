defmodule EzagentWeb.UrlHelperTest do
  use ExUnit.Case, async: false

  alias EzagentWeb.UrlHelper

  defp conn(host), do: %Plug.Conn{host: host}

  describe "request_base_url/1 — trusted hosts use the request host" do
    test "canary.ezagent.chat yields a canary base URL (NOT the configured nightly host)" do
      assert UrlHelper.request_base_url(conn("canary.ezagent.chat")) ==
               "https://canary.ezagent.chat"
    end

    test "nightly.ezagent.chat yields a nightly base URL" do
      assert UrlHelper.request_base_url(conn("nightly.ezagent.chat")) ==
               "https://nightly.ezagent.chat"
    end

    test "the apex ezagent.chat is trusted" do
      assert UrlHelper.request_base_url(conn("ezagent.chat")) == "https://ezagent.chat"
    end

    test "localhost is trusted" do
      assert UrlHelper.request_base_url(conn("localhost")) == "https://localhost"
    end

    test "an arbitrary *.ezagent.chat subdomain is trusted" do
      assert UrlHelper.request_base_url(conn("app.ezagent.chat")) == "https://app.ezagent.chat"
    end
  end

  describe "request_base_url/1 — host-header injection guard" do
    test "an untrusted host falls back to Endpoint.url/0 and never echoes the attacker host" do
      result = UrlHelper.request_base_url(conn("evil.example.com"))
      assert result == EzagentWeb.Endpoint.url()
      refute result =~ "evil.example.com"
    end

    test "a look-alike suffix (ezagent.chat.evil.com) is NOT trusted" do
      result = UrlHelper.request_base_url(conn("ezagent.chat.evil.com"))
      assert result == EzagentWeb.Endpoint.url()
      refute result =~ "evil.com"
    end

    test "a bare substring (myezagent.chat is not *.ezagent.chat) is NOT trusted" do
      # "myezagent.chat" does not end with ".ezagent.chat" (no dot boundary).
      result = UrlHelper.request_base_url(conn("myezagent.chat"))
      assert result == EzagentWeb.Endpoint.url()
    end
  end

  describe "request_base_url/1 — scheme/port from :ezagent_domain_session config" do
    setup do
      scheme = Application.get_env(:ezagent_domain_session, :public_scheme)
      port = Application.get_env(:ezagent_domain_session, :public_port)

      on_exit(fn ->
        restore(:public_scheme, scheme)
        restore(:public_port, port)
      end)

      :ok
    end

    test "non-default port is appended to the authority" do
      Application.put_env(:ezagent_domain_session, :public_scheme, "https")
      Application.put_env(:ezagent_domain_session, :public_port, 8443)

      assert UrlHelper.request_base_url(conn("canary.ezagent.chat")) ==
               "https://canary.ezagent.chat:8443"
    end

    test "http scheme on the default http port omits the port" do
      Application.put_env(:ezagent_domain_session, :public_scheme, "http")
      Application.put_env(:ezagent_domain_session, :public_port, 80)

      assert UrlHelper.request_base_url(conn("localhost")) == "http://localhost"
    end

    test "http scheme on a non-default port appends it" do
      Application.put_env(:ezagent_domain_session, :public_scheme, "http")
      Application.put_env(:ezagent_domain_session, :public_port, 4000)

      assert UrlHelper.request_base_url(conn("localhost")) == "http://localhost:4000"
    end
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:ezagent_domain_session, key, value)
end
