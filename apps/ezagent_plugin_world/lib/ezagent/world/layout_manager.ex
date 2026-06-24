defmodule Ezagent.World.LayoutManager do
  @moduledoc """
  File-backed layout store for the `world` plugin.

  Layout is runtime data, not runtime code. The server validates component
  type references against the typed-slot registry (`Ezagent.World.SlotRegistry`)
  before anything is persisted or pushed back to React. The registry is the
  唯一真源 — this module no longer keeps its own allowlist.

  ## Storage seam (plugin-resource SPEC §4.4)

  Layout bytes are addressed by `resource://<ws>/world-layouts/<name>` and
  resolved through `Ezagent.Resource.FsResolver.resolve/2` — the hardened
  tenant-scoped FS seam — NOT raw `Ezagent.Home.path/1`. The `world-layouts`
  `<type>` is contributed by `EzagentPluginWorld.Application.resource_types/0`.

  ## R-3 — the caller scope is SEPARATE from the target URI (codex HIGH-4)

  `read_layout/2` and `write_layout/3` take TWO independent arguments:

    * `scope_uri` — the layout's TARGET workspace (`self_uri` of the
      `workspace`-Kind Behavior); the bytes' address is derived from this.
    * `scope` — the CALLER's authenticated authorization context
      (`%{workspace: <name|uri>}`), derived from `ctx.caller` at the cap-checked
      Behavior dispatch — NEVER from `scope_uri`.

  The resolver's per-type `authority/2` asserts the resolved URI's `<ws>` equals
  `scope.workspace`. Because the two `<ws>` values come from independent sources
  (the target URI vs. the authenticated caller), the check is non-tautological:
  a target `scope_uri` naming a FOREIGN workspace resolved under a different
  caller `scope` is REJECTED, not silently resolved.
  """

  alias Ezagent.Resource.FsResolver
  alias Ezagent.World.SlotRegistry

  @layout_version 1

  # The plugin-contributed resource `<type>` (single-segment, slug-prefixed —
  # `EzagentPluginWorld.Application.resource_types/0`).
  @resource_type "world-layouts"

  @type layout :: map()
  @type scope :: FsResolver.scope()

  @doc "Registered build-time component types accepted by world layouts."
  @spec registered_component_types() :: MapSet.t(String.t())
  def registered_component_types, do: SlotRegistry.layout_slot_types()

  @doc """
  Read the persisted layout for `scope_uri` under the caller's authenticated
  `scope`, falling back to the default layout.

  Any resolver miss/rejection (unregistered type, foreign-workspace authority
  failure, absent file, decode/validation error) falls back to
  `default_layout/1` — fail-CLOSED: a foreign-workspace target never yields the
  foreign layout's bytes.
  """
  @spec read_layout(URI.t(), scope()) :: layout()
  def read_layout(%URI{} = scope_uri, %{workspace: _} = scope) do
    with {:ok, path} <- resolve_layout_path(scope_uri, scope),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, layout} <- validate_layout(scope_uri, decoded) do
      layout
    else
      _ -> default_layout(scope_uri)
    end
  end

  @doc """
  Validate and persist a layout for `scope_uri` under the caller's authenticated
  `scope`. Returns `{:error, _}` (and writes nothing) when the caller scope is
  not authoritative for the target workspace (R-3).
  """
  @spec write_layout(URI.t(), map(), scope()) :: {:ok, layout()} | {:error, term()}
  def write_layout(%URI{} = scope_uri, %{} = layout, %{workspace: _} = scope) do
    with {:ok, normalized} <- validate_layout(scope_uri, layout),
         {:ok, path} <- resolve_layout_path(scope_uri, scope),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(normalized, pretty: true),
         :ok <- File.write(path, encoded) do
      {:ok, normalized}
    end
  end

  def write_layout(%URI{}, _, %{workspace: _}), do: {:error, :invalid_layout}

  @doc "Default world layout for a workspace scope."
  @spec default_layout(URI.t()) :: layout()
  def default_layout(%URI{} = scope_uri) do
    scope = scope_string(scope_uri)

    %{
      "version" => @layout_version,
      "scope" => scope,
      "components" => [
        %{
          "id" => "layout-editor",
          "type" => "layout_editor",
          "placement" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 2},
          "props" => %{"title" => "Layout"}
        },
        %{
          "id" => "sessions-table",
          "type" => "sessions_table",
          "placement" => %{"x" => 0, "y" => 2, "w" => 12, "h" => 6},
          "props" => %{"title" => "Sessions"}
        }
      ]
    }
  end

  @doc "Validate a layout and normalize optional fields."
  @spec validate_layout(URI.t(), map()) :: {:ok, layout()} | {:error, term()}
  def validate_layout(%URI{} = scope_uri, %{} = layout) do
    scope = scope_string(scope_uri)

    with :ok <- validate_version(layout),
         :ok <- validate_scope(scope_uri, layout),
         {:ok, components} <- validate_components(Map.get(layout, "components")) do
      {:ok,
       %{
         "version" => @layout_version,
         "scope" => scope,
         "components" => components
       }}
    end
  end

  def validate_layout(%URI{}, _), do: {:error, :invalid_layout}

  defp validate_version(%{"version" => @layout_version}), do: :ok
  defp validate_version(%{"version" => version}), do: {:error, {:unsupported_version, version}}
  defp validate_version(_), do: {:error, :missing_version}

  defp validate_scope(scope_uri, %{"scope" => scope}) when is_binary(scope) do
    if scope == URI.to_string(scope_uri), do: :ok, else: {:error, :scope_mismatch}
  end

  defp validate_scope(_scope_uri, _layout), do: {:error, :missing_scope}

  defp validate_components(components) when is_list(components) and components != [] do
    components
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, acc} ->
      case validate_component(component) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = err -> err
    end
  end

  defp validate_components(_), do: {:error, :invalid_components}

  defp validate_component(%{"id" => id, "type" => type} = component)
       when is_binary(id) and id != "" and is_binary(type) and type != "" do
    with :ok <- validate_component_type(type),
         {:ok, placement} <- validate_placement(Map.get(component, "placement", %{})),
         {:ok, props} <- validate_props(Map.get(component, "props", %{})) do
      {:ok, %{"id" => id, "type" => type, "placement" => placement, "props" => props}}
    end
  end

  defp validate_component(_), do: {:error, :invalid_component}

  defp validate_component_type(type) do
    if SlotRegistry.layout_slot?(type) do
      :ok
    else
      {:error, {:unknown_component_type, type}}
    end
  end

  defp validate_placement(%{} = placement) do
    normalized = %{
      "x" => Map.get(placement, "x", 0),
      "y" => Map.get(placement, "y", 0),
      "w" => Map.get(placement, "w", 12),
      "h" => Map.get(placement, "h", 1)
    }

    if Enum.all?(normalized, fn {_key, value} -> is_integer(value) and value >= 0 end) do
      {:ok, normalized}
    else
      {:error, :invalid_placement}
    end
  end

  defp validate_placement(_), do: {:error, :invalid_placement}

  defp validate_props(%{} = props), do: {:ok, props}
  defp validate_props(_), do: {:error, :invalid_props}

  # Build `resource://<ws>/world-layouts/<name>` from the layout's TARGET
  # `scope_uri`, then resolve it through the hardened FS seam under the CALLER's
  # authenticated `scope` (R-3 — the two `<ws>` sources are independent). The
  # resolver runs `world_layout_authority/2` (`uri.<ws> == scope.workspace`)
  # BEFORE returning a path, so a foreign-workspace target under a different
  # caller is rejected here, not silently resolved.
  @spec resolve_layout_path(URI.t(), scope()) :: {:ok, String.t()} | {:error, term()}
  defp resolve_layout_path(%URI{} = scope_uri, %{workspace: _} = scope) do
    with {:ok, ws} <- Ezagent.URI.workspace_name(scope_uri) do
      uri = Ezagent.URI.resource(ws, @resource_type, scope_key(scope_uri))

      case FsResolver.resolve(uri, scope) do
        {:ok, path} -> {:ok, path}
        :none -> {:error, {:unregistered_resource_type, @resource_type}}
        {:error, _} = err -> err
      end
    else
      :error -> {:error, {:malformed_scope_uri, URI.to_string(scope_uri)}}
    end
  end

  @doc """
  The opaque `<name>` segment for `scope_uri`'s layout — the stable URL-safe
  encoding of the URI's canonical key. Shared with the one-shot migration task
  so a legacy file's stem maps byte-identically to its new resolver `<name>`.
  """
  @spec scope_key(URI.t()) :: String.t()
  def scope_key(%URI{} = scope_uri) do
    scope_uri
    |> Ezagent.URI.stable_key()
    |> Base.url_encode64(padding: false)
  end

  defp scope_string(%URI{} = scope_uri), do: URI.to_string(scope_uri)
end
