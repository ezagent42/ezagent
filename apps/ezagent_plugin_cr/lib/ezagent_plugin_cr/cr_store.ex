defmodule EzagentPluginCr.CrStore do
  @moduledoc """
  One-CR-per-tenant store backed by `Ezagent.Socialware.ConfigStore`.

  A tenant always has at most one active (draft) change request at a time.
  Once published, the next `ensure_active_cr/2` mints a fresh draft.

  ## Storage layout

  - layer:        `"workspace"`
  - workspace_uri: `"workspace://<tid>"`
  - subject_uri:  `"workspace://<tid>"`  (same; workspace-level singleton)
  - key:          `"cr"`
  - source_turn_id: `"cr-store"`

  The `body` map stored in `ConfigStore` is the CR map itself:
  ```
  %{
    "cr_id"              => "cr-<8hex>",
    "status"             => "draft" | "published",
    "created_by"         => actor_uri,
    "published_version"  => nil | pos_integer(),
    "notes"              => ""
  }
  ```
  """

  alias Ezagent.Socialware.ConfigStore

  @layer "workspace"
  @key "cr"
  @source_turn_id "cr-store"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Return the tenant's current draft CR, creating one if none exists or the
  last one was published.

  `actor_uri` is recorded as `created_by` when a fresh draft is minted.
  """
  @spec ensure_active_cr(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_active_cr(tenant_id, actor_uri) when is_binary(tenant_id) and is_binary(actor_uri) do
    ws = workspace_uri(tenant_id)

    case ConfigStore.resolve(@layer, ws, ws, @key) do
      {:ok, %{body: %{"status" => "draft"} = body}} ->
        {:ok, body}

      _ ->
        # Either :none (no CR yet) or body has status "published" — mint new draft.
        fresh = %{
          "cr_id" => "cr-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)),
          "status" => "draft",
          "created_by" => actor_uri,
          "published_version" => nil,
          "notes" => ""
        }

        case ConfigStore.write_and_point(%{
               layer: @layer,
               workspace_uri: ws,
               subject_uri: ws,
               key: @key,
               body: fresh,
               actor_uri: actor_uri,
               source_turn_id: @source_turn_id
             }) do
          {:ok, _result} -> {:ok, fresh}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Fetch the current CR for a tenant.

  Returns `{:ok, body_map}` or `{:error, :not_found}` when no CR exists.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(tenant_id) when is_binary(tenant_id) do
    ws = workspace_uri(tenant_id)

    case ConfigStore.resolve(@layer, ws, ws, @key) do
      {:ok, %{body: body}} -> {:ok, body}
      :none -> {:error, :not_found}
    end
  end

  @doc """
  Mark the current draft CR as published, setting `published_version`.

  Verifies that `cr_id` matches the active record (returns
  `{:error, :cr_mismatch}` if not). Updates the stored body in-place via
  a new `write_and_point` over the same key.
  """
  @spec mark_published(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def mark_published(tenant_id, cr_id, version)
      when is_binary(tenant_id) and is_binary(cr_id) and is_integer(version) and version > 0 do
    ws = workspace_uri(tenant_id)

    case ConfigStore.resolve(@layer, ws, ws, @key) do
      {:ok, %{body: body}} ->
        if body["cr_id"] != cr_id do
          {:error, :cr_mismatch}
        else
          updated = %{body | "status" => "published", "published_version" => version}

          # actor_uri reuses cr_id (store operation — no human actor here)
          actor_uri = body["created_by"] || "system://cr-store"

          case ConfigStore.write_and_point(%{
                 layer: @layer,
                 workspace_uri: ws,
                 subject_uri: ws,
                 key: @key,
                 body: updated,
                 actor_uri: actor_uri,
                 source_turn_id: @source_turn_id
               }) do
            {:ok, _result} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      :none ->
        {:error, :cr_mismatch}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp workspace_uri(tenant_id), do: "workspace://#{tenant_id}"
end
