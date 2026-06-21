defmodule Ezagent.Uploads do
  @moduledoc """
  Chat-attachment upload store, workspace-partitioned behind the hardened
  `Ezagent.Resource.FsResolver` (Resource-unification P2b).

  Attachments are addressed as `resource://<ws>/uploads/<name>` (workspace-first,
  SPEC v3 3-segment authority) and their bytes live at
  `Home.path("uploads")/<ws>/<name>` — **ws-partitioned**, so the same filename in
  two workspaces is isolated on disk.

  ## Why this changed (P2b)

  Pre-P2 this module resolved uploads by *basename* under a single
  `Home.path("uploads")/<name>` directory (no `<ws>` partition) and owned its own
  `Ezagent.UriQuery` `:upload_path` resolver. That made the on-disk layout
  flat-namespaced and the download authorization participation-based at the
  controller. P2b routes store + read through the generic, authorization-bearing
  `FsResolver` `uploads` type (`authority/2` = `uri.<ws> == scope.workspace`), so
  the workspace boundary is structural and `Ezagent.Home.path/1` is reached only
  at the resolver's sanctioned R-4 chokepoint — this module no longer calls
  `Home.path/1`.

  Resolution is **authorization-bearing**: `resolve/2` and `path!/2` REQUIRE a
  `scope` whose `:workspace` comes from the caller's authenticated context, never
  from the URI being resolved.
  """

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  @type_segment "uploads"

  @typedoc "The caller's authenticated workspace scope (see `FsResolver.scope/0`)."
  @type scope :: FsResolver.scope()

  @doc "The `resource://` type segment for chat uploads."
  @spec type_segment() :: String.t()
  def type_segment, do: @type_segment

  @doc """
  Build a `resource://<ws>/uploads/<name>` URI for a stored upload name.
  """
  @spec resource_uri(String.t(), String.t()) :: URI.t()
  def resource_uri(workspace_name, stored_name)
      when is_binary(workspace_name) and is_binary(stored_name) do
    EzURI.resource(workspace_name, @type_segment, stored_name)
  end

  @doc """
  Resolve an upload `resource://<ws>/uploads/<name>` URI to its on-disk path
  under the caller's authenticated `scope`, via the hardened `FsResolver`.

  Returns `{:ok, path}` | `:none` (not an uploads URI) | `{:error, reason}`
  (unsafe segment / foreign-workspace authority failure).
  """
  @spec resolve(URI.t(), scope()) :: {:ok, String.t()} | :none | {:error, term()}
  def resolve(%URI{} = uri, %{workspace: _} = scope) do
    # Enforce the uploads `<type>` at THIS boundary (codex MEDIUM): the generic
    # `FsResolver` would happily resolve any registered type (e.g. a config-dir
    # `<ns>-agents` URI in the same workspace), and `UploadToken` could in
    # principle carry such a URI. The uploads download surface must only ever
    # serve uploads bytes, so a non-uploads resource URI is `:none` here —
    # defense in depth that does not depend on the minting caller being honest.
    if EzURI.type?(uri, @type_segment) do
      FsResolver.resolve(uri, scope)
    else
      :none
    end
  end

  @doc """
  Resolve an upload URI to its path, raising on `:none` / `{:error, _}`.

  `scope` is the caller's authenticated workspace context.
  """
  @spec path!(URI.t(), scope()) :: String.t()
  def path!(%URI{} = uri, %{workspace: _} = scope) do
    case resolve(uri, scope) do
      {:ok, path} when is_binary(path) ->
        path

      :none ->
        raise ArgumentError, "not an upload resource: #{inspect(uri)}"

      {:error, reason} ->
        raise ArgumentError, "could not resolve upload path: #{inspect(reason)}"
    end
  end

  @doc """
  Copy a LiveView upload temp file into the ws-partitioned upload store and
  return its `resource://<ws>/uploads/<name>` URI.

  The destination is resolved through `FsResolver` under a scope derived from the
  same `workspace_name` (the authenticated upload workspace), so a malformed /
  unsafe `stored_name` is rejected before any byte is written.
  """
  @spec store!(String.t(), String.t(), String.t()) :: URI.t()
  def store!(workspace_name, stored_name, tmp_path)
      when is_binary(workspace_name) and is_binary(stored_name) and is_binary(tmp_path) do
    uri = resource_uri(workspace_name, stored_name)
    dest = path!(uri, %{workspace: workspace_name})
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(tmp_path, dest)
    uri
  end

  @doc """
  Store a client upload by its RAW filename: generate a collision-proof
  `<uuid>-<sanitized>` stored name, then `store!/3` it under `workspace_name`.
  Returns `{uri, stored_name}`. Owning the naming here keeps every upload surface
  (the world HTTP controller, and any CLI/API adapter) on ONE sanitize + naming
  path, so an unsafe client name can't reach `store!`.
  """
  @spec store_upload!(String.t(), String.t(), String.t()) :: {URI.t(), String.t()}
  def store_upload!(workspace_name, client_filename, tmp_path)
      when is_binary(workspace_name) and is_binary(tmp_path) do
    stored_name = "#{Ecto.UUID.generate()}-#{sanitize_stored_name(client_filename)}"
    {store!(workspace_name, stored_name, tmp_path), stored_name}
  end

  @doc """
  Sanitize a client filename into a safe stored-name segment: basename only,
  non-`[\\w.-]` runs collapsed to `_`, clamped to 200 chars, never empty.
  """
  @spec sanitize_stored_name(term()) :: String.t()
  def sanitize_stored_name(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^\w\.\-]+/, "_")
    |> String.slice(0, 200)
    |> case do
      "" -> "file"
      s -> s
    end
  end

  def sanitize_stored_name(_), do: "file"
end
