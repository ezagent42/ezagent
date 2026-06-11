defmodule EzagentPluginCr.Publisher do
  @moduledoc """
  Full-sandbox publish flow for a tenant's content.

  Publishes the tenant's sandbox as an immutable versioned release directory,
  atomically flips `_current` to the new version, and records the CR as
  published.

  ## Publish flow

  1. Lint gate (`Lint.run/1`) — warnings are advisory, fatal errors abort.
  2. Ensure an active CR (`CrStore.ensure_active_cr/2`).
  3. Allocate the next version number.
  4. Copy sandbox → `release/v<n>/` (full copy).
  5. Atomically flip `_current` symlink → `v<n>`.
  6. Mark CR as published.

  The symlink pointer only ever points to a fully materialized version
  directory (build-then-flip guarantee).

  ## `init_tenant/2`

  Bootstrap a brand-new tenant: copy the platform skeleton into the sandbox
  and immediately publish it as v1.

  ## `rollback/3`

  Operational pointer move: flip `_current` back to an existing version
  without touching the CR.
  """

  alias EzagentPluginContent.TenantPaths
  alias EzagentPluginCr.{CrStore, Lint}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec publish(tid :: String.t(), actor_uri :: String.t()) ::
          {:ok, %{version: pos_integer(), warnings: [String.t()]}} | {:error, term()}
  def publish(tid, actor_uri) when is_binary(tid) and is_binary(actor_uri) do
    with {:ok, warnings} <- Lint.run(tid),
         {:ok, cr} <- CrStore.ensure_active_cr(tid, actor_uri),
         {:ok, n} <- allocate_version(tid),
         vdir = TenantPaths.release_dir(tid, n),
         {:ok, _} <- copy_sandbox(tid, vdir),
         :ok <- flip_current(tid, vdir),
         :ok <- CrStore.mark_published(tid, cr["cr_id"], n) do
      {:ok, %{version: n, warnings: warnings}}
    end
  end

  @doc """
  Bootstrap a brand-new tenant by provisioning the platform skeleton into
  the sandbox and immediately publishing it as v1.

  Returns `{:ok, :already_initialized}` if the sandbox already exists.
  Returns `{:ok, %{version: 1, warnings: []}}` on a fresh init.
  """
  @spec init_tenant(tid :: String.t(), actor_uri :: String.t()) ::
          {:ok, :already_initialized}
          | {:ok, %{version: pos_integer(), warnings: [String.t()]}}
          | {:error, term()}
  def init_tenant(tid, actor_uri) when is_binary(tid) and is_binary(actor_uri) do
    sandbox = TenantPaths.sandbox_dir(tid)

    if File.dir?(sandbox) do
      {:ok, :already_initialized}
    else
      with :ok <- File.mkdir_p(Path.dirname(sandbox)),
           {:ok, _} <- File.cp_r(TenantPaths.skeleton_dir(), sandbox) do
        publish(tid, actor_uri)
      end
    end
  end

  @doc """
  Operational pointer rollback: flip `_current` to an existing version dir
  without any CR involvement.

  Returns `{:error, :no_such_version}` if the target version dir does not
  exist.
  """
  @spec rollback(tid :: String.t(), to_version :: pos_integer(), actor_uri :: String.t()) ::
          {:ok, %{version: pos_integer()}} | {:error, term()}
  def rollback(tid, to_version, _actor_uri)
      when is_binary(tid) and is_integer(to_version) and to_version > 0 do
    vdir = TenantPaths.release_dir(tid, to_version)

    if File.dir?(vdir) do
      case flip_current(tid, vdir) do
        :ok -> {:ok, %{version: to_version}}
        err -> err
      end
    else
      {:error, :no_such_version}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp allocate_version(tid) do
    release_root = TenantPaths.release_root(tid)

    with :ok <- File.mkdir_p(release_root) do
      existing =
        case File.ls(release_root) do
          {:ok, entries} -> entries
          {:error, _} -> []
        end

      max_n =
        existing
        |> Enum.flat_map(fn name ->
          if String.starts_with?(name, "v") do
            case Integer.parse(String.trim_leading(name, "v")) do
              {n, ""} when n > 0 -> [n]
              _ -> []
            end
          else
            []
          end
        end)
        |> Enum.max(fn -> 0 end)

      {:ok, max_n + 1}
    end
  end

  defp copy_sandbox(tid, vdir) do
    sandbox = TenantPaths.sandbox_dir(tid)

    if File.dir?(sandbox) do
      File.cp_r(sandbox, vdir)
    else
      {:error, :no_sandbox}
    end
  end

  defp flip_current(tid, vdir) do
    link = TenantPaths.current_link(tid)
    tmp = link <> ".tmp"
    _ = File.rm(tmp)

    with :ok <- :file.make_symlink(String.to_charlist(vdir), String.to_charlist(tmp)),
         :ok <- :file.rename(tmp, link),
         do: :ok
  end
end
