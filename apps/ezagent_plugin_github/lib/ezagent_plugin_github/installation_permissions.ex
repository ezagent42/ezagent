defmodule EzagentPluginGithub.InstallationPermissions do
  @moduledoc """
  Closed map from a `t:profile/0` to the exact GitHub App permission set an
  installation access token mint request may ask for.

  There is no caller-supplied or dynamic profile: `EzagentPluginGithub.GitHubAdapter`
  selects the profile statically per callback (see its moduledoc), so this module's
  only job is translating that closed atom into the exact `permissions` map GitHub's
  `POST /app/installations/{id}/access_tokens` expects. Adding an operation that
  needs a new permission set means adding a new profile here — never widening an
  existing one or accepting a caller-supplied permission map.
  """

  @type profile :: :metadata_read | :change_request_write | :change_request_read | :checks_read

  @doc """
  Returns the exact GitHub permissions map for `profile`.

  Raises `FunctionClauseError` for any atom outside the closed set — there is no
  fallback or wildcard profile.
  """
  @spec for!(profile()) :: %{String.t() => String.t()}
  def for!(:metadata_read), do: %{"metadata" => "read"}

  def for!(:change_request_write),
    do: %{"metadata" => "read", "contents" => "write", "pull_requests" => "write"}

  def for!(:change_request_read), do: %{"metadata" => "read", "pull_requests" => "read"}
  def for!(:checks_read), do: %{"metadata" => "read", "checks" => "read"}
end
