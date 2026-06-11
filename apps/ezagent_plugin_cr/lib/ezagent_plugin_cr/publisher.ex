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
  5. Mark CR as published (DB write BEFORE pointer flip).
  6. Atomically flip `_current` symlink → `v<n>`.

  ## Mark-before-flip ordering

  We intentionally write the DB record (mark_published) before flipping the
  `_current` symlink. The alternative ordering (flip → mark) creates an
  unrecoverable orphan: if the process crashes after the flip but before the
  DB write, `_current` points at vN while the CR still reads "published vN-1";
  a subsequent publish call will allocate vN+1, leaving vN unreachable.

  The chosen ordering is safely recoverable: a crash after mark_published but
  before flip leaves the CR saying "published vN" while `_current` still points
  at vN-1. `repair_current/1` detects this gap and re-runs the flip (the vN dir
  is fully materialized).

  ## `init_tenant/2`

  Bootstrap a brand-new tenant: copy the platform skeleton into the sandbox
  and immediately publish it as v1.

  If the sandbox exists but `_current` does not resolve (half-init: cp_r
  succeeded, first publish crashed), `init_tenant/2` resumes by calling
  `publish/2` directly instead of returning `:already_initialized`.

  ## `repair_current/1`

  Detects and heals the mark-before-flip gap: if the CR is "published vN" but
  `_current` does not resolve to v<N> while the v<N> dir exists, flip
  `_current` to v<N>.

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
         :ok <- CrStore.mark_published(tid, cr["cr_id"], n),
         :ok <- flip_current(tid, vdir) do
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
      # Half-init guard: sandbox exists but _current never resolved (cp_r
      # succeeded on a previous call, but the publish step crashed before
      # flip_current completed). Resume by publishing rather than declaring
      # :already_initialized — skipping the skeleton copy since the sandbox is
      # already populated.
      case TenantPaths.current_dir(tid) do
        {:ok, _} -> {:ok, :already_initialized}
        {:error, _} -> publish(tid, actor_uri)
      end
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

  @doc """
  Detect and heal the mark-before-flip gap.

  Reads the CR for `tid`. If the CR status is "published" with version `n` and
  `_current` does NOT resolve to `v<n>` while the `v<n>` directory exists,
  flips `_current` to `v<n>` and returns `{:ok, :repaired}`.

  Returns `{:ok, :consistent}` when the symlink already points at the right
  version (or when no CR exists yet).
  """
  @spec repair_current(tid :: String.t()) :: {:ok, :repaired | :consistent} | {:error, term()}
  def repair_current(tid) when is_binary(tid) do
    case CrStore.get(tid) do
      {:error, :not_found} ->
        {:ok, :consistent}

      {:ok, cr} ->
        if cr["status"] == "published" do
          n = cr["published_version"]
          vdir = TenantPaths.release_dir(tid, n)

          already_pointing? =
            case TenantPaths.current_dir(tid) do
              {:ok, current} -> current == vdir
              {:error, _} -> false
            end

          if already_pointing? or not File.dir?(vdir) do
            {:ok, :consistent}
          else
            case flip_current(tid, vdir) do
              :ok -> {:ok, :repaired}
              err -> err
            end
          end
        else
          {:ok, :consistent}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp allocate_version(tid) do
    release_root = TenantPaths.release_root(tid)

    with :ok <- File.mkdir_p(release_root),
         {:ok, entries} <- read_release_entries(release_root) do
      max_n =
        entries
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

  # File.ls/1 on a directory that was just mkdir_p'd should always succeed.
  # :enoent means the dir wasn't created yet (shouldn't happen after mkdir_p,
  # but treat it as empty so v1 is allocated). Any other error (e.g. :eacces)
  # propagates as {:error, {:release_root_unreadable, reason}} so callers know
  # the release root exists but is unreadable — masking it would silently
  # allocate v1 and overwrite any existing releases.
  defp read_release_entries(release_root) do
    case File.ls(release_root) do
      {:ok, entries} -> {:ok, entries}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:release_root_unreadable, reason}}
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
