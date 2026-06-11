defmodule EzagentPluginContent.TenantPaths do
  @moduledoc "Tenant content roots: sandbox (admin edits) vs release/_current (agents read)."

  @safe_segment ~r/^[a-zA-Z0-9_-]+$/

  @spec tenant_root(String.t()) :: String.t()
  def tenant_root(tid),
    do: Path.join([Ezagent.Home.profile_dir(), "tenants", safe!(tid, "tenant id")])

  @spec sandbox_dir(String.t()) :: String.t()
  def sandbox_dir(tid), do: Path.join(tenant_root(tid), "sandbox")

  @spec release_root(String.t()) :: String.t()
  def release_root(tid), do: Path.join(tenant_root(tid), "release")

  @spec release_dir(String.t(), non_neg_integer()) :: String.t()
  def release_dir(tid, n), do: Path.join(release_root(tid), "v#{n}")

  @spec current_link(String.t()) :: String.t()
  def current_link(tid), do: Path.join(release_root(tid), "_current")

  @spec current_dir(String.t()) :: {:ok, String.t()} | {:error, :no_release}
  def current_dir(tid) do
    link = current_link(tid)

    case File.read_link(link) do
      {:ok, target} ->
        resolved = Path.expand(target, release_root(tid))

        if String.starts_with?(resolved, release_root(tid) <> "/"),
          do: {:ok, resolved},
          else: {:error, :no_release}

      {:error, _} ->
        {:error, :no_release}
    end
  end

  @spec work_dir(String.t(), String.t()) :: String.t()
  def work_dir(tid, role),
    do: Path.join([tenant_root(tid), "cc-agents", "#{safe!(role, "role")}-work"])

  @spec skeleton_dir() :: String.t()
  def skeleton_dir, do: Path.join(:code.priv_dir(:ezagent_plugin_content), "skeleton")

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp safe!(segment, label) do
    if is_binary(segment) and Regex.match?(@safe_segment, segment),
      do: segment,
      else:
        raise(
          ArgumentError,
          "#{label} must match #{inspect(@safe_segment.source)}, got: #{inspect(segment)}"
        )
  end
end
