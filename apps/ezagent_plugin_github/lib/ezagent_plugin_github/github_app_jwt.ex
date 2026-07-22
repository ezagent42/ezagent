defmodule EzagentPluginGithub.GitHubAppJwt do
  @moduledoc """
  Signs the short-lived JSON Web Token that authenticates AS THE GitHub App.

  A GitHub App proves its identity to GitHub with an `RS256` JWT signed by the
  App's private key. That JWT is the credential used to list installations and to
  mint installation access tokens (see `EzagentPluginGithub.GitHubInstallation`);
  it is NOT used directly for repository REST calls.

  Per GitHub's contract (verified against docs.github.com):

    * `alg` MUST be `RS256`; the token is signed with the App's RSA private key.
    * `iss` is the App identifier (this plugin uses `app_id`).
    * `iat` is backdated 60 seconds to tolerate clock drift between us and GitHub.
    * `exp` must be no more than 10 minutes past GitHub's clock. We use 9 minutes
      (`+540s`) so positive local clock skew cannot push `exp` past the hard cap
      and trigger a 401.

  Signing uses pure OTP (`:public_key.sign/3` with `:sha256`, i.e. RSASSA-PKCS1
  over SHA-256 = RS256) — no external JWT dependency. The private key never leaves
  this process and is never logged.
  """

  alias EzagentPluginGithub.Config

  # iat backdate (clock drift) and exp window (< GitHub's 10-minute hard cap).
  @iat_backdate_seconds 60
  @exp_window_seconds 540

  @doc """
  Builds and signs a GitHub App JWT from the configured `app_id` and private key.

  Raises (fail-loud) if the private key is missing or malformed — a
  misconfigured App must not silently produce an unusable token.
  """
  @spec generate() :: String.t()
  def generate do
    generate(Config.app_id(), Config.private_key())
  end

  @doc """
  Builds and signs a GitHub App JWT for `app_id` using `private_key` (an Erlang
  `:public_key` private-key record), at `now` (Unix seconds, defaults to the
  current system time). Exposed for deterministic testing.
  """
  @spec generate(String.t(), tuple(), integer()) :: String.t()
  def generate(app_id, private_key, now \\ System.system_time(:second))
      when is_binary(app_id) and is_integer(now) do
    header = %{"alg" => "RS256", "typ" => "JWT"}

    claims = %{
      "iat" => now - @iat_backdate_seconds,
      "exp" => now + @exp_window_seconds,
      "iss" => app_id
    }

    signing_input = "#{encode_segment(header)}.#{encode_segment(claims)}"
    signature = :public_key.sign(signing_input, :sha256, private_key)

    "#{signing_input}.#{Base.url_encode64(signature, padding: false)}"
  end

  defp encode_segment(map) do
    map |> Jason.encode!() |> Base.url_encode64(padding: false)
  end
end
