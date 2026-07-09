defmodule Ezagent.ConfigGovernance.Store do
  @moduledoc """
  Thin store for CR (change-request) config governance (SPEC
  `docs/together/2026-06-26/specs/cr-config-governance.md`, rev 3). Owns ONLY
  the `ConfigChangeRequest` / `ConfigChangeItem` rows; delegates EVERY config
  read/write to `Ezagent.Socialware.ConfigStore`
  (`write_object_staged/1`, `fetch_matching_object/1`, `put_pointer/1`,
  `resolve/4`, `fetch_object/1`, `merge_delta/5`).

  The lifecycle (open → published, + rejected, rolled_back) is enforced here as
  pure functions; authorization (the agent's manage-cap) + CE-1 self-binding +
  sandbox materialization live in the dispatched behavior
  `Ezagent.ActionSet.ConfigGovernance`. This module performs NO authorization —
  it is the durable lifecycle engine the behavior drives.

  ## Stage = write an inert object now, point NO layer (§4.2)

  `stage_item/1` writes a REAL immutable `ConfigObject` via
  `ConfigStore.write_object_staged/1` (fenced `cr-stage:<cr>:<item>` turn_id, no
  pointer) and records a `ConfigChangeItem`. The orphan-object invariant stays
  sound because the staged turn_id is a reserved CR namespace.

  ## Publish = one Multi (§4.3.1)

  `publish/1` runs ALL per-item guard+flip in ONE `Repo.transaction`
  (all-or-nothing): per-item drift guard (`resolve/4` still == `base_object_id`),
  scope guard (`fetch_matching_object/1`), pointer flip (`put_pointer/1`),
  capturing the returned `previous_config_id` into `published_prev_object_id`.
  The status gate (`open → published` one-way) is the publish idempotency
  mechanism — checked BEFORE any pointer write.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ezagent.Socialware.{ConfigChangeItem, ConfigChangeRequest, ConfigObject, ConfigStore}
  alias EzagentCore.Repo

  @cr_stage_prefix "cr-stage:"
  @cr_publish_prefix "cr-publish:"

  # ---- open / fetch --------------------------------------------------------

  @doc """
  Open a CR for `subject_uri` (an agent). Fails if an `open` CR already exists
  for that subject (partial unique index). No config side effect.
  """
  @spec open(map()) :: {:ok, ConfigChangeRequest.t()} | {:error, term()}
  def open(attrs) when is_map(attrs) do
    cr_attrs = %{
      id: Map.get(attrs, :id) || Ecto.UUID.generate(),
      workspace_uri: uri_string!(Map.fetch!(attrs, :workspace_uri)),
      subject_uri: uri_string!(Map.fetch!(attrs, :subject_uri)),
      status: "open",
      opened_by: uri_string!(Map.fetch!(attrs, :opened_by)),
      title: Map.get(attrs, :title),
      note: Map.get(attrs, :note)
    }

    cr_attrs
    |> ConfigChangeRequest.changeset()
    |> Repo.insert()
  end

  @spec fetch(String.t()) :: {:ok, ConfigChangeRequest.t()} | :none
  def fetch(cr_id) when is_binary(cr_id) do
    case Repo.get(ConfigChangeRequest, cr_id) do
      %ConfigChangeRequest{} = cr -> {:ok, cr}
      nil -> :none
    end
  end

  @doc "List items for a CR (ordered by insertion)."
  @spec items(String.t()) :: [ConfigChangeItem.t()]
  def items(cr_id) when is_binary(cr_id) do
    Repo.all(
      from(i in ConfigChangeItem, where: i.change_request_id == ^cr_id, order_by: i.inserted_at)
    )
  end

  @doc "List CRs for a subject (newest first)."
  @spec list_for_subject(URI.t() | String.t()) :: [ConfigChangeRequest.t()]
  def list_for_subject(subject_uri) do
    subject = uri_string!(subject_uri)

    Repo.all(
      from(cr in ConfigChangeRequest,
        where: cr.subject_uri == ^subject,
        order_by: [desc: cr.inserted_at]
      )
    )
  end

  # ---- stage / unstage (CR stays open) -------------------------------------

  @doc """
  Stage (or re-stage) a `(layer, key)` slot on an `open` CR: write an inert
  immutable `ConfigObject` (no pointer) and upsert the `ConfigChangeItem`.

  Body = an explicit `replace_body` OR `merge_delta/5` of `patch` onto the
  current resolved body (identical to `ConfigEvolve.do_apply_config_delta`).
  `base_object_id` = the slot's current `resolve/4` object id (`:none` ⇒ nil).
  """
  @spec stage_item(map()) :: {:ok, ConfigChangeItem.t()} | {:error, term()}
  def stage_item(attrs) when is_map(attrs) do
    with {:ok, cr} <- require_open(Map.fetch!(attrs, :change_request_id)),
         {:ok, layer} <- ConfigStore.normalize_layer(Map.fetch!(attrs, :layer)),
         {:ok, key} <- ConfigStore.validate_key(Map.fetch!(attrs, :key)) do
      workspace_uri = cr.workspace_uri
      subject_uri = cr.subject_uri
      item_id = Map.get(attrs, :id) || Ecto.UUID.generate()
      actor_uri = uri_string!(Map.fetch!(attrs, :actor_uri))

      body = stage_body(attrs, layer, workspace_uri, subject_uri, key)
      base_object_id = current_object_id(layer, workspace_uri, subject_uri, key)

      object_attrs = %{
        workspace_uri: workspace_uri,
        subject_uri: subject_uri,
        key: key,
        body: body,
        actor_uri: actor_uri,
        source_turn_id: "#{@cr_stage_prefix}#{cr.id}:#{item_id}"
      }

      Multi.new()
      |> Multi.run(:object, fn _repo, _ -> ConfigStore.write_object_staged(object_attrs) end)
      |> Multi.run(:item, fn _repo, %{object: object} ->
        upsert_item(%{
          id: item_id,
          change_request_id: cr.id,
          workspace_uri: workspace_uri,
          layer: layer,
          key: key,
          staged_object_id: object.id,
          base_object_id: base_object_id
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{item: item}} -> {:ok, item}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Unstage a slot: delete the `ConfigChangeItem`. The orphan `ConfigObject` is
  left append-only and unreferenced (same as a superseded object today).
  """
  @spec unstage_item(map()) :: {:ok, :unstaged} | {:error, term()}
  def unstage_item(attrs) when is_map(attrs) do
    with {:ok, cr} <- require_open(Map.fetch!(attrs, :change_request_id)),
         {:ok, layer} <- ConfigStore.normalize_layer(Map.fetch!(attrs, :layer)),
         {:ok, key} <- ConfigStore.validate_key(Map.fetch!(attrs, :key)) do
      {count, _} =
        Repo.delete_all(
          from(i in ConfigChangeItem,
            where: i.change_request_id == ^cr.id and i.layer == ^layer and i.key == ^key
          )
        )

      if count > 0, do: {:ok, :unstaged}, else: {:error, :item_not_found}
    end
  end

  # ---- preview (pure read, no side effect, no checks) ----------------------

  @doc """
  Per-item preview (§5): `{layer, key, current_body, proposed_body}` for every
  staged item. A pure read over existing reads — nothing persisted/materialized.
  The behavior layers the deterministic `render_soul/1` diff on top.
  """
  @spec preview(String.t()) :: {:ok, [map()]} | {:error, term()}
  def preview(cr_id) when is_binary(cr_id) do
    case fetch(cr_id) do
      {:ok, cr} ->
        diffs =
          cr_id
          |> items()
          |> Enum.map(fn item ->
            %{
              layer: item.layer,
              key: item.key,
              staged_object_id: item.staged_object_id,
              current_body: resolve_body(item.layer, cr.workspace_uri, cr.subject_uri, item.key),
              proposed_body: object_body(item.staged_object_id)
            }
          end)

        {:ok, diffs}

      :none ->
        {:error, :cr_not_found}
    end
  end

  # ---- publish (open → published; one Multi) -------------------------------

  @doc """
  Publish a CR (`open → published`). Status-gated idempotency (a second publish
  on a `published` CR is rejected BEFORE any pointer write). For each item, in
  ONE Multi: drift guard → scope guard (`fetch_matching_object/1`) → flip
  (`put_pointer/1`) → capture `previous_config_id` into
  `published_prev_object_id`. Then status → published, set `published_by` /
  `published_turn_id`.

  Returns `{:ok, %{cr: cr, items: [item], published_turn_id: id}}`.

  ## Two-layer publish idempotency (MED-1 defense-in-depth)

  The `open → published` one-way transition is enforced at TWO layers, so a
  double-publish is impossible regardless of how the store is called:

    1. **Pre-check (`require_open/1`)** — outside the transaction. Catches the
       ordinary SEQUENTIAL re-publish (a second publish on a `published` CR)
       and returns `{:error, {:cr_status, ...}}` before any work.
    2. **In-`Multi` guard (`WHERE status = 'open'`)** — the FIRST Multi step is
       an `update_all` that flips status only WHERE it is still `open`, asserting
       exactly one row matched (`{:error, :not_open}` otherwise). This `UPDATE`
       takes the CR row lock BEFORE any pointer write, so two CONCURRENT
       publishes serialize on that row — the loser matches zero rows and aborts
       the whole Multi (its pointer flips roll back). This closes the publish
       TOCTOU even if two publishes ever interleave off the per-agent actor.
  """
  @spec publish(map()) :: {:ok, map()} | {:error, term()}
  def publish(attrs) when is_map(attrs) do
    cr_id = Map.fetch!(attrs, :change_request_id)
    published_by = uri_string!(Map.fetch!(attrs, :published_by))
    pointed_by = published_by

    # STATUS GATE FIRST (pre-check) — `open → published` is the publish
    # idempotency mechanism (a second publish is rejected before any pointer
    # write). The in-Multi WHERE-guard below is the concurrent defense-in-depth.
    with {:ok, cr} <- require_open(cr_id) do
      published_turn_id = "#{@cr_publish_prefix}#{cr.id}"
      items = items(cr_id)
      now = DateTime.utc_now()

      # Step 1: gate-and-flip status WHERE it is still `open`, asserting exactly
      # one row updated. This `UPDATE` locks the CR row before any pointer work,
      # so a concurrent publish that already committed `published` matches 0 rows
      # here and aborts the whole Multi (rolling back its own flips). The updated
      # struct is rebuilt from the in-hand `cr` (no extra read / no `returning`).
      Multi.new()
      |> Multi.update_all(
        :cr_update,
        from(c in ConfigChangeRequest, where: c.id == ^cr.id and c.status == "open"),
        set: [
          status: "published",
          published_by: published_by,
          published_turn_id: published_turn_id,
          updated_at: now
        ]
      )
      |> Multi.run(:cr, fn _repo, %{cr_update: {count, _}} ->
        case count do
          1 ->
            {:ok,
             %{
               cr
               | status: "published",
                 published_by: published_by,
                 published_turn_id: published_turn_id,
                 updated_at: now
             }}

          _ ->
            {:error, :not_open}
        end
      end)
      |> Multi.run(:flip, fn _repo, _ ->
        flip_items(items, cr, published_turn_id, pointed_by)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{cr: updated_cr, flip: published_items}} ->
          {:ok, %{cr: updated_cr, items: published_items, published_turn_id: published_turn_id}}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # Per-item guard+flip inside the publish transaction. All-or-nothing: any
  # error (drift / scope / pointer) aborts the whole Multi → nothing flipped.
  defp flip_items(items, cr, published_turn_id, pointed_by) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case flip_item(item, cr, published_turn_id, pointed_by) do
        {:ok, updated_item} -> {:cont, {:ok, [updated_item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      {:error, _} = error -> error
    end
  end

  defp flip_item(item, cr, published_turn_id, pointed_by) do
    flip_attrs = %{
      layer: item.layer,
      workspace_uri: cr.workspace_uri,
      subject_uri: cr.subject_uri,
      key: item.key,
      config_id: item.staged_object_id,
      actor_uri: pointed_by,
      source_turn_id: published_turn_id
    }

    with :ok <- assert_no_drift(item, cr),
         {:ok, _object} <- ConfigStore.fetch_matching_object(flip_attrs),
         {:ok, %{previous_config_id: previous}} <- ConfigStore.put_pointer(flip_attrs) do
      item
      |> ConfigChangeItem.publish_changeset(%{published_prev_object_id: previous})
      |> Repo.update()
    end
  end

  # base-drift conflict (§4.4) — config must NOT have moved under the open CR
  # since staging. `resolve/4` must still resolve to `base_object_id`
  # (`:none`/nil ⇒ the slot was empty at stage AND must still be empty).
  defp assert_no_drift(item, cr) do
    current = current_object_id(item.layer, cr.workspace_uri, cr.subject_uri, item.key)

    if current == item.base_object_id,
      do: :ok,
      else: {:error, {:cr_base_drift, %{item_id: item.id, layer: item.layer, key: item.key}}}
  end

  # ---- reject (open → rejected) --------------------------------------------

  @doc "Reject a CR (`open → rejected`). No config side effect — nothing was ever pointed-to."
  @spec reject(String.t()) :: {:ok, ConfigChangeRequest.t()} | {:error, term()}
  def reject(cr_id) when is_binary(cr_id) do
    with {:ok, cr} <- require_open(cr_id) do
      cr
      |> ConfigChangeRequest.status_changeset(%{status: "rejected"})
      |> Repo.update()
    end
  end

  # ---- rollback (published → rolled_back) — caller drives the repoints ------

  @doc """
  Mark a published CR `rolled_back`. The actual per-slot repoints (to each
  item's `published_prev_object_id`) are driven by the behavior via the EXISTING
  `ConfigEvolve.repoint_config` — this only gates the status transition
  (`published → rolled_back`) and returns the items so the caller knows each
  slot's durable rollback target.
  """
  @spec mark_rolled_back(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_rolled_back(cr_id) when is_binary(cr_id) do
    with {:ok, cr} <- require_status(cr_id, "published") do
      cr
      |> ConfigChangeRequest.status_changeset(%{status: "rolled_back"})
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, %{cr: updated, items: items(cr_id)}}
        {:error, _} = error -> error
      end
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp require_open(cr_id), do: require_status(cr_id, "open")

  defp require_status(cr_id, status) do
    case fetch(cr_id) do
      {:ok, %ConfigChangeRequest{status: ^status} = cr} ->
        {:ok, cr}

      {:ok, %ConfigChangeRequest{status: other}} ->
        {:error, {:cr_status, %{want: status, got: other}}}

      :none ->
        {:error, :cr_not_found}
    end
  end

  defp stage_body(attrs, layer, workspace_uri, subject_uri, key) do
    case Map.get(attrs, :replace_body) do
      %{} = replacement ->
        replacement

      _ ->
        patch = Map.get(attrs, :patch) || %{}
        ConfigStore.merge_delta(layer, workspace_uri, subject_uri, key, patch)
    end
  end

  defp upsert_item(item_attrs) do
    item_attrs
    |> ConfigChangeItem.changeset()
    |> Repo.insert(
      on_conflict: {:replace, [:staged_object_id, :base_object_id, :updated_at]},
      conflict_target: [:change_request_id, :layer, :key]
    )
  end

  defp current_object_id(layer, workspace_uri, subject_uri, key) do
    case ConfigStore.resolve(layer, workspace_uri, subject_uri, key) do
      {:ok, %ConfigObject{id: id}} -> id
      :none -> nil
    end
  end

  defp resolve_body(layer, workspace_uri, subject_uri, key) do
    case ConfigStore.resolve(layer, workspace_uri, subject_uri, key) do
      {:ok, %ConfigObject{body: body}} -> body || %{}
      :none -> %{}
    end
  end

  defp object_body(object_id) do
    case ConfigStore.fetch_object(object_id) do
      {:ok, %ConfigObject{body: body}} -> body || %{}
      :none -> %{}
    end
  end

  defp uri_string!(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string!(uri) when is_binary(uri) and uri != "", do: uri

  defp uri_string!(other),
    do: raise(ArgumentError, "expected URI or URI string, got: #{inspect(other)}")
end
