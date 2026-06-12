defmodule Ezagent.Socialware.ConfigStore do
  @moduledoc """
  Immutable config objects plus high-layer cascade pointers for SW-UPD.

  A config update writes a new object, then repoints a high layer to the new id.
  Rollback is the same repoint operation aimed at a prior retained object.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ezagent.Socialware.{ConfigObject, ConfigPointer}
  alias EzagentCore.Repo

  @layers ~w(workspace user session)

  @type write_result :: %{
          required(:config_id) => String.t(),
          required(:object) => ConfigObject.t(),
          required(:pointer) => ConfigPointer.t(),
          required(:previous_config_id) => String.t() | nil
        }

  # PR-7 (LOW) — the public object-only insert (`write_config/1`) was REMOVED.
  # The ONLY public durable-write path is now the atomic `write_and_point/1`
  # (object + pointer in one transaction). A public object-only insert let a
  # caller create an ORPHAN object (object with no pointer advancing to it),
  # breaking the "object-existence ⟺ applied" invariant the PR-6/7 recovery +
  # idempotency logic now relies on (`applied_for_turn?/1`, `object_for_turn/1`).
  # Tests that legitimately need an object WITHOUT a pointer (config-object
  # materialization by URI; the unique-constraint check) build the changeset
  # directly via the `ConfigObject` schema (no production entry point).

  @spec write_and_point(map()) :: {:ok, write_result()} | {:error, term()}
  def write_and_point(attrs) when is_map(attrs) do
    object_attrs = object_attrs(attrs)

    Multi.new()
    |> Multi.insert(:object, ConfigObject.changeset(object_attrs))
    |> Multi.run(:pointer, fn _repo, %{object: object} ->
      put_pointer(Map.put(attrs, :config_id, object.id))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{object: object, pointer: %{pointer: pointer, previous_config_id: previous}}} ->
        {:ok,
         %{config_id: object.id, object: object, pointer: pointer, previous_config_id: previous}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @spec put_pointer(map()) ::
          {:ok, %{pointer: ConfigPointer.t(), previous_config_id: String.t() | nil}}
          | {:error, term()}
  def put_pointer(attrs) when is_map(attrs) do
    attrs = pointer_attrs(attrs)

    with %ConfigObject{} <-
           Repo.get(ConfigObject, Map.fetch!(attrs, :config_id)) || {:error, :config_not_found} do
      previous =
        attrs.layer
        |> ConfigPointer.id(attrs.workspace_uri, attrs.subject_uri, attrs.key)
        |> then(&Repo.get(ConfigPointer, &1))

      previous_config_id = if previous, do: previous.config_id
      attrs = Map.put(attrs, :previous_config_id, previous_config_id)

      attrs
      |> ConfigPointer.changeset()
      |> Repo.insert(
        on_conflict:
          {:replace, [:config_id, :previous_config_id, :pointed_by, :source_turn_id, :updated_at]},
        conflict_target: :id
      )
      |> case do
        {:ok, pointer} -> {:ok, %{pointer: pointer, previous_config_id: previous_config_id}}
        {:error, _changeset} = error -> error
      end
    end
  end

  @doc """
  Non-raising layer validation/normalization (#607 round-5 — single source of
  truth for the allow-list). Returns `{:ok, canonical_string}` for any of the
  allowed layers (atom or string), or `{:error, {:invalid_layer, details}}`.

  Both this and the raising `normalize_layer!/1` (used at the write boundary in
  `pointer_attrs/1`) draw from the SAME `@layers` allow-list, so an upfront
  caller cannot pass a value that is accepted here yet rejected at the write
  (and vice versa). The upfront validator (`ConfigUpdate.validate_and_normalize/2`)
  uses this so an invalid `layer` is rejected loud BEFORE any side effect rather
  than raising inside `put_pointer` after the sandbox has already been mutated.
  """
  @spec normalize_layer(atom() | String.t() | term()) ::
          {:ok, String.t()} | {:error, {:invalid_layer, map()}}
  def normalize_layer(layer) when is_atom(layer) and not is_nil(layer),
    do: layer |> Atom.to_string() |> normalize_layer()

  def normalize_layer(layer) when is_binary(layer) and layer in @layers, do: {:ok, layer}

  def normalize_layer(other),
    do: {:error, {:invalid_layer, %{got: inspect(other), allowed: @layers}}}

  @doc """
  Non-raising key validation (#607 round-5). `key` reaches both the immutable
  object changeset (`validate_required`) and the pointer key/id. Reject a
  missing/blank/non-string key upfront, loud, BEFORE any side effect.
  """
  @spec validate_key(term()) :: {:ok, String.t()} | {:error, {:invalid_key, map()}}
  def validate_key(key) when is_binary(key) and key != "", do: {:ok, key}

  def validate_key(other),
    do: {:error, {:invalid_key, %{got: inspect(other)}}}

  @doc """
  Non-raising URI validation/normalization (#607 round-5). A `%URI{}` or non-empty
  string is accepted and canonicalized to a `%URI{}` (the canonical form the
  downstream consumers want: `CascadeRepoint.repoint_user_layer/3` requires a
  `%URI{}` subject, and `uri_string!/1` at the ConfigStore write boundary accepts
  either). Anything else is rejected loud BEFORE any side effect, mirroring the
  raising `uri_string!/1`.
  """
  @spec normalize_uri(term(), atom()) :: {:ok, URI.t()} | {:error, {:invalid_uri, map()}}
  def normalize_uri(%URI{} = uri, _field), do: {:ok, uri}

  def normalize_uri(uri, _field) when is_binary(uri) and uri != "",
    do: {:ok, Ezagent.URI.new!(uri)}

  def normalize_uri(other, field),
    do: {:error, {:invalid_uri, %{field: field, got: inspect(other)}}}

  @spec resolve(atom() | String.t(), URI.t() | String.t(), URI.t() | String.t(), String.t()) ::
          {:ok, ConfigObject.t()} | :none
  def resolve(layer, workspace_uri, subject_uri, key) do
    layer = normalize_layer!(layer)
    workspace = uri_string!(workspace_uri)
    subject = uri_string!(subject_uri)

    pointer =
      Repo.one(
        from(p in ConfigPointer,
          where:
            p.layer == ^layer and p.workspace_uri == ^workspace and p.subject_uri == ^subject and
              p.key == ^key
        )
      )

    case pointer do
      %ConfigPointer{config_id: config_id} -> {:ok, get!(config_id)}
      nil -> :none
    end
  end

  @spec resolve!(atom() | String.t(), URI.t() | String.t(), URI.t() | String.t(), String.t()) ::
          ConfigObject.t()
  def resolve!(layer, workspace_uri, subject_uri, key) do
    case resolve(layer, workspace_uri, subject_uri, key) do
      {:ok, object} -> object
      :none -> raise KeyError, key: {layer, workspace_uri, subject_uri, key}, term: __MODULE__
    end
  end

  @spec get!(String.t()) :: ConfigObject.t()
  def get!(config_id), do: Repo.get!(ConfigObject, config_id)

  @doc """
  The current `:user`-layer config object id for `agent_uri` (its own user
  cascade layer). Thin wrapper over `resolve/4` keyed by the agent's
  workspace + the standard cascade key, returning just the object id.

  Used by `Ezagent.Behavior.ConfigEvolve`'s step-2 projection + boot
  reconciliation to read the durable pointer the Sandbox cache must mirror.
  Returns `{:ok, object_id}` or `:none` (no user-layer pointer yet).
  """
  @spec current_user_object(URI.t(), String.t()) :: {:ok, String.t()} | :none
  def current_user_object(%URI{} = agent_uri, key) when is_binary(key) do
    case Ezagent.URI.workspace_of(agent_uri) do
      %URI{} = workspace_uri ->
        case resolve(:user, workspace_uri, agent_uri, key) do
          {:ok, %ConfigObject{id: id}} -> {:ok, id}
          :none -> :none
        end

      :any ->
        :none
    end
  end

  @doc """
  CE-3 — OBJECT-EXISTENCE durable idempotency marker for `apply_config_delta`
  recovery.

  A settled config delta is "applied" for a turn iff a `ConfigObject` stamped
  with `source_turn_id == turn_id` exists. This is sound because
  `write_and_point/1` writes the immutable object AND advances the pointer in
  ONE `Repo.transaction` — an orphan object (object inserted, pointer not
  advanced) can NO LONGER occur. So "an object for turn T exists" ⟺ "turn T
  was durably applied", and a genuinely-interrupted apply (the transaction
  never committed) leaves NEITHER object nor pointer → `false` → recovery
  correctly replays.

  PR-6: this REVERTS the PR-5 pointer-aware join. Keying on the pointer
  resolving to the object was not only unnecessary under atomicity, it
  REGRESSED superseded turns: applying turn B on top of turn A advances the
  pointer off A's object, which flipped `applied_for_turn?("A")` back to
  `false` and made recovery REPLAY an already-applied, merely-superseded turn.
  Object existence is permanent (objects are append-only / never deleted), so
  a superseded turn correctly stays applied.

  `Turn.config_replay_needed?/2` uses this to decide whether a settled turn's
  config delta still needs replaying.
  """
  @spec applied_for_turn?(String.t()) :: boolean()
  def applied_for_turn?(turn_id) when is_binary(turn_id) do
    Repo.exists?(from(o in ConfigObject, where: o.source_turn_id == ^turn_id))
  end

  @doc """
  CE-2/CE-3 (PR-7) — OBJECT-EXISTENCE idempotency lookup: the id of the
  `ConfigObject` whose `source_turn_id == turn_id`, or `:none`.

  This is the OBJECT-EXISTENCE companion to `applied_for_turn?/1` (which only
  returns a boolean). It does NOT join the CURRENT pointer, so it is consistent
  for a SUPERSEDED turn: applying turn B on top of turn A leaves A's object
  intact (objects are append-only), so `object_for_turn(A)` still resolves A's
  historical id even after the pointer has advanced off A onto B.

  Used by `Ezagent.Behavior.ConfigEvolve` to make `apply_config_delta`
  idempotent on BOTH the serial pre-check AND the unique-constraint conflict
  path: re-dispatching ANY already-applied turn (current OR superseded) returns
  that turn's historical object id (a string) instead of minting a new object —
  satisfying the `config_id: :string` action contract. The `write_and_point/1`
  unique index on `(workspace, subject, key, source_turn_id)` guarantees at
  most one object per turn, so this is unambiguous.
  """
  @spec object_for_turn(String.t()) :: {:ok, String.t()} | :none
  def object_for_turn(turn_id) when is_binary(turn_id) do
    case Repo.one(
           from(o in ConfigObject, where: o.source_turn_id == ^turn_id, select: o.id, limit: 1)
         ) do
      nil -> :none
      object_id -> {:ok, object_id}
    end
  end

  @doc """
  Fetch an immutable config object by id.

  Returns `{:ok, object}` or `:none` (no such object). Used by
  `Ezagent.Socialware.ConfigProjection.resolve_config_dir/1` to materialize the
  SPECIFIC immutable object an object-keyed cascade-layer URI names.
  """
  @spec fetch_object(String.t()) :: {:ok, ConfigObject.t()} | :none
  def fetch_object(object_id) when is_binary(object_id) do
    case Repo.get(ConfigObject, object_id) do
      %ConfigObject{} = object -> {:ok, object}
      nil -> :none
    end
  end

  @doc """
  Fetch the immutable config object named by `attrs.config_id` and validate it
  is in scope for the authorized target.

  This is the pre-side-effect guard for the `repoint`/rollback path (#607 codex
  round-4 HIGH): `handle_repoint` authorizes the caller-supplied
  `workspace_uri`/`subject_uri`, but the `config_id` is also caller-supplied and
  names an EXISTING immutable object. Without this check the agent's sandbox could
  be repointed at a nonexistent object URI (next materialization fails loud) or at
  an object belonging to ANOTHER workspace/subject (a mismatched pointer) BEFORE
  `put_pointer` ever runs `Repo.get`. Validate the object exists and its
  `workspace_uri`, `subject_uri`, AND `key` match the authorized attrs BEFORE any
  side effect (repoint + pointer write).

  Returns:
    * `{:ok, object}` — the object exists and is in scope.
    * `{:error, :config_not_found}` — no object with that id.
    * `{:error, {:cross_tenant_target, details}}` — the object exists but its
      workspace/subject/key do not match the authorized attrs (loud).
  """
  @spec fetch_matching_object(map()) ::
          {:ok, ConfigObject.t()}
          | {:error, :config_not_found}
          | {:error, {:cross_tenant_target, map()}}
  def fetch_matching_object(attrs) when is_map(attrs) do
    config_id = Map.fetch!(attrs, :config_id)
    workspace = attrs |> Map.fetch!(:workspace_uri) |> uri_string!()
    subject = attrs |> Map.fetch!(:subject_uri) |> uri_string!()
    key = Map.fetch!(attrs, :key)

    case Repo.get(ConfigObject, config_id) do
      nil ->
        {:error, :config_not_found}

      %ConfigObject{workspace_uri: ^workspace, subject_uri: ^subject, key: ^key} = object ->
        {:ok, object}

      %ConfigObject{} = object ->
        {:error,
         {:cross_tenant_target,
          %{
            field: :config_id,
            config_id: config_id,
            expected: %{workspace_uri: workspace, subject_uri: subject, key: key},
            got: %{
              workspace_uri: object.workspace_uri,
              subject_uri: object.subject_uri,
              key: object.key
            }
          }}}
    end
  end

  @spec merge_delta(
          atom() | String.t(),
          URI.t() | String.t(),
          URI.t() | String.t(),
          String.t(),
          map()
        ) ::
          map()
  def merge_delta(layer, workspace_uri, subject_uri, key, patch) when is_map(patch) do
    base =
      case resolve(layer, workspace_uri, subject_uri, key) do
        {:ok, object} -> object.body
        :none -> %{}
      end

    Map.merge(base, stringify_keys(patch))
  end

  defp object_attrs(attrs) do
    %{
      id: Map.get(attrs, :id) || Ecto.UUID.generate(),
      workspace_uri: attrs |> Map.fetch!(:workspace_uri) |> uri_string!(),
      subject_uri: attrs |> Map.fetch!(:subject_uri) |> uri_string!(),
      key: Map.fetch!(attrs, :key),
      body: attrs |> Map.fetch!(:body) |> stringify_keys(),
      created_by: attrs |> Map.fetch!(:actor_uri) |> uri_string!(),
      source_turn_id: Map.fetch!(attrs, :source_turn_id)
    }
  end

  defp pointer_attrs(attrs) do
    layer = attrs |> Map.fetch!(:layer) |> normalize_layer!()
    workspace_uri = attrs |> Map.fetch!(:workspace_uri) |> uri_string!()
    subject_uri = attrs |> Map.fetch!(:subject_uri) |> uri_string!()
    key = Map.fetch!(attrs, :key)

    %{
      id: ConfigPointer.id(layer, workspace_uri, subject_uri, key),
      layer: layer,
      workspace_uri: workspace_uri,
      subject_uri: subject_uri,
      key: key,
      config_id: Map.fetch!(attrs, :config_id),
      pointed_by: attrs |> Map.fetch!(:actor_uri) |> uri_string!(),
      source_turn_id: Map.fetch!(attrs, :source_turn_id)
    }
  end

  defp normalize_layer!(layer) when is_atom(layer),
    do: layer |> Atom.to_string() |> normalize_layer!()

  defp normalize_layer!(layer) when is_binary(layer) and layer in @layers, do: layer

  defp normalize_layer!(other),
    do: raise(ArgumentError, "invalid socialware config layer: #{inspect(other)}")

  defp uri_string!(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string!(uri) when is_binary(uri) and uri != "", do: uri

  defp uri_string!(other),
    do: raise(ArgumentError, "expected URI or URI string, got: #{inspect(other)}")

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {string_key!(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp string_key!(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key!(key) when is_binary(key), do: key
  defp string_key!(key), do: raise(ArgumentError, "invalid config key: #{inspect(key)}")
end
