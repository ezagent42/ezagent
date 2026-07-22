defmodule EzagentPluginGithub.GitHubAppJwtTest do
  # async: false — the config-reading tests mutate global application env.
  use ExUnit.Case, async: false

  alias EzagentPluginGithub.GitHubAppJwt
  alias EzagentPluginGithub.TestHelpers

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    # RSAPrivateKey record: {:RSAPrivateKey, version, modulus, publicExponent, ...}
    public_key = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    %{key: key, public_key: public_key}
  end

  describe "generate/3" do
    test "produces an RS256 JWT with the correct header", %{key: key} do
      jwt = GitHubAppJwt.generate("4361756", key)
      assert [header_b64, _claims_b64, _sig_b64] = String.split(jwt, ".")

      header = header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert header == %{"alg" => "RS256", "typ" => "JWT"}
    end

    test "sets iss=app_id, backdated iat, and exp under GitHub's 10-min cap", %{key: key} do
      now = System.system_time(:second)
      jwt = GitHubAppJwt.generate("4361756", key, now)
      [_header, claims_b64, _sig] = String.split(jwt, ".")

      claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert claims["iss"] == "4361756"
      assert claims["iat"] == now - 60
      assert claims["exp"] == now + 540
      # Never past GitHub's hard 10-minute (600s) cap, even with local clock skew.
      assert claims["exp"] - now <= 600
    end

    test "signature verifies against the RSA public key with SHA-256", ctx do
      now = System.system_time(:second)
      jwt = GitHubAppJwt.generate("4361756", ctx.key, now)
      [header_b64, claims_b64, sig_b64] = String.split(jwt, ".")

      signing_input = header_b64 <> "." <> claims_b64
      signature = Base.url_decode64!(sig_b64, padding: false)

      assert :public_key.verify(signing_input, :sha256, signature, ctx.public_key)
    end

    test "a tampered payload fails verification", ctx do
      jwt = GitHubAppJwt.generate("4361756", ctx.key)
      [header_b64, _claims_b64, sig_b64] = String.split(jwt, ".")

      forged_claims =
        %{"iss" => "999", "iat" => 0, "exp" => 9_999_999_999}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      signing_input = header_b64 <> "." <> forged_claims
      signature = Base.url_decode64!(sig_b64, padding: false)

      refute :public_key.verify(signing_input, :sha256, signature, ctx.public_key)
    end
  end

  describe "generate/0 (config-driven)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_github, :app_id)
        Application.delete_env(:ezagent_plugin_github, :private_key)
      end)

      :ok
    end

    test "reads app_id and the private key from application config" do
      Application.put_env(:ezagent_plugin_github, :app_id, "4361756")

      Application.put_env(
        :ezagent_plugin_github,
        :private_key,
        TestHelpers.test_private_key_pem()
      )

      jwt = GitHubAppJwt.generate()
      [_header, claims_b64, _sig] = String.split(jwt, ".")
      claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert claims["iss"] == "4361756"
    end

    test "fails loud on a malformed (non-PEM) private key" do
      Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
      Application.put_env(:ezagent_plugin_github, :private_key, "-----not a pem-----")

      assert_raise RuntimeError, ~r/Invalid GITHUB_APP_PRIVATE_KEY/, fn ->
        GitHubAppJwt.generate()
      end
    end

    test "fails loud on a missing private key" do
      Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
      Application.delete_env(:ezagent_plugin_github, :private_key)

      assert_raise RuntimeError, ~r/Missing (config|env var)/, fn ->
        GitHubAppJwt.generate()
      end
    end
  end
end
