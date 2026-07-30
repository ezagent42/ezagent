defmodule EzagentPluginForgejo.Instance do
  @moduledoc """
  Derives a Forgejo instance's API base URL from a binding's provider host.

  Forgejo is self-hosted: unlike GitHub — whose adapter can hardcode
  `https://api.github.com` — every binding names its own instance, and two
  bindings in the same VM routinely point at different ones (design
  `docs/superpowers/specs/2026-07-29-forgejo-provider-v1-design.md` §5.2). The
  base URL is therefore derived per call from
  `Ezagent.DomainGit.RepositoryRef.provider_host`, never read from a global
  config key.

  `provider_host` is a bare host (optionally `host:port`) — the repo's existing
  values are `"github.com"`, `"git.example.test"`. Anything carrying a scheme,
  path, userinfo or whitespace is rejected rather than interpolated: this
  function decides which host a Forgejo PAT is transmitted to, so a malformed
  binding row must fail closed instead of silently addressing another server.
  """

  # Bare host or host:port. An allowlist, not a blocklist -- a rejected input
  # here is a misconfigured binding, and enumerating the ways a host can be
  # wrong is strictly harder than stating what a host may contain.
  @host ~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?\z/

  @doc """
  Builds the v1 API base URL for a Forgejo instance's provider host.

      iex> EzagentPluginForgejo.Instance.api_base("code.hyprial.com")
      {:ok, "https://code.hyprial.com/api/v1"}

      iex> EzagentPluginForgejo.Instance.api_base("https://code.hyprial.com")
      {:error, :invalid_provider_host}
  """
  @spec api_base(term()) :: {:ok, String.t()} | {:error, :invalid_provider_host}
  def api_base(provider_host) when is_binary(provider_host) do
    if String.match?(provider_host, @host) do
      {:ok, "https://#{provider_host}/api/v1"}
    else
      {:error, :invalid_provider_host}
    end
  end

  def api_base(_provider_host), do: {:error, :invalid_provider_host}
end
