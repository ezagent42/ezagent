defmodule EzagentPluginGithub.GitHubWebhookVerifierTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.GitHubWebhookVerifier

  doctest GitHubWebhookVerifier

  @secret "webhook-secret-token"
  @body ~s({"action":"opened","number":1})

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  describe "verify/3" do
    test "accepts a correct sha256 HMAC over the raw body" do
      assert :ok = GitHubWebhookVerifier.verify(@body, sign(@body, @secret), @secret)
    end

    test "rejects a signature for a tampered body" do
      signature = sign(@body, @secret)
      tampered = @body <> " "

      assert {:error, :invalid_signature} =
               GitHubWebhookVerifier.verify(tampered, signature, @secret)
    end

    test "rejects a signature computed with the wrong secret" do
      signature = sign(@body, "different-secret")

      assert {:error, :invalid_signature} =
               GitHubWebhookVerifier.verify(@body, signature, @secret)
    end

    test "rejects a header missing the sha256= prefix" do
      hex = :crypto.mac(:hmac, :sha256, @secret, @body) |> Base.encode16(case: :lower)

      assert {:error, :invalid_signature} = GitHubWebhookVerifier.verify(@body, hex, @secret)
    end

    test "reports a missing signature header distinctly" do
      assert {:error, :missing_signature} = GitHubWebhookVerifier.verify(@body, nil, @secret)
    end
  end
end
