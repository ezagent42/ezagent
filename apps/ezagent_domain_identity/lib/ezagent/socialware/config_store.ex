defmodule Ezagent.Socialware.ConfigStore do
  @moduledoc """
  Immutable config objects plus high-layer cascade pointers for SW-UPD.

  A config update writes a new object, then repoints a high layer to the new id.
  Rollback is the same repoint operation aimed at a prior retained object.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ezagent.Socialware.{ConfigObject, ConfigPointer, ContentHash}
  alias EzagentCore.Repo

  @layers ~w(workspace user session)

  # CR-governance reserved `source_turn_id` prefixes. A staged ConfigObject
  # carries `cr-stage:<cr_id>:<item_id>` (a CR-owned namespace, NEVER a real
  # settled `turn_id`), and a CR publish stamps `cr-publish:<cr_id>` on the
  # flipped pointers. These are reserved so:
  #   * a staged object's idempotency lookup (`applied_for_turn?`/
  #     `object_for_turn`) can never collide with a real turn's marker; and
  #   * a caller cannot pass a `cr-stage:`/`cr-publish:` turn_id to the NORMAL
  #     write/repoint path (`apply_config_delta`/`Agent.Config`) and spoof a
  #     same-turn idempotency early-return / settled-turn provenance.
  # The fence: `write_object_staged/1` REQUIRES a `cr-stage:` prefix, and every
  # NON-CR write/repoint entry point REJECTS both prefixes (see
  # `reserved_turn_prefix?/1`).
  @cr_stage_prefix "cr-stage:"
  @cr_publish_prefix "cr-publish:"
  @reserved_turn_prefixes [@cr_stage_prefix, @cr_publish_prefix]

  @type write_result :: %{
          required(:config_id) => String.t(),
          required(:object) => ConfigObject.t(),
          required(:pointer) => ConfigPointer.t(),
          required(:previous_config_id) => String.t() | nil
        }

  @type pointer_with_object :: %{
          required(:pointer) => ConfigPointer.t(),
          required(:object) => ConfigObject.t()
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

  @doc """
  CR-governance — write an INERT immutable `ConfigObject` (object only, NO
  pointer) for a staged change-request item (SPEC §4.2.1).

  PR-7 removed the public object-only insert because an orphan object (object
  with no pointer) would break the "object existence ⟺ applied" invariant
  (`applied_for_turn?/1`, `object_for_turn/1`). A staged object IS an object
  with no pointer — so this path is FENCED: it REQUIRES a `cr-stage:` prefixed
  `source_turn_id` (a CR-owned namespace that can never be a real settled turn),
  rejecting anything else loud. That keeps the PR-7 invariant sound: a staged
  object's `source_turn_id` never collides with a real turn's idempotency
  marker, so `applied_for_turn?(real_turn)` is unaffected.

  Returns `{:ok, ConfigObject.t()}` or `{:error, term()}`.
  """
  @spec write_object_staged(map()) :: {:ok, ConfigObject.t()} | {:error, term()}
  def write_object_staged(attrs) when is_map(attrs) do
    attrs = object_attrs(attrs)

    case Map.fetch!(attrs, :source_turn_id) do
      @cr_stage_prefix <> _rest ->
        attrs
        |> ConfigObject.changeset()
        |> Repo.insert()

      other ->
        {:error, {:not_cr_stage_turn_id, %{got: other, required_prefix: @cr_stage_prefix}}}
    end
  end

  @doc """
  Role-as-data seed primitive (SPEC §4.1/§4.2) — atomically write an immutable
  `ConfigObject` AND point its layer IFF no pointer yet exists for the object's
  `(layer, workspace, subject, key)`.

  This is the seed-once-if-no-pointer primitive built-in role seeding needs. It
  is NOT `write_and_point/1`: that one's `put_pointer/1` UPSERTS
  (`on_conflict: {:replace, ...}`) and would CLOBBER a tenant's published
  override on every reboot. Here the pointer existence is checked + the
  object/pointer inserted in ONE `Repo.transaction`, with the pointer insert
  using `on_conflict: :nothing` so a concurrent seed (or a tenant publish racing
  a boot) that already created the pointer leaves it untouched and rolls back
  this transaction's object insert (no orphan object).

  Idempotency + override-safety:
    * no pointer → object + pointer written → `{:ok, :seeded}`.
    * pointer exists, SAME `body` → no-op → `{:ok, :exists}` (re-seed is safe).
    * pointer exists, DIFFERENT `body` → `{:error, collision_tag}` (the moved
      two-plugins-one-name boot-collision guard; `collision_tag` is the
      caller-supplied loud error term).

  `attrs` requires `:layer, :workspace_uri, :subject_uri, :key, :body,
  :actor_uri, :source_turn_id` (same shape as `write_and_point/1`) plus a
  `:collision_tag` term returned on a divergent-body collision.
  """
  @spec seed_object_if_no_pointer(map()) ::
          {:ok, :seeded | :exists} | {:error, term()}
  def seed_object_if_no_pointer(attrs) when is_map(attrs) do
    do_seed_if_no_pointer(attrs, _retry? = true)
  end

  defp do_seed_if_no_pointer(attrs, retry?) do
    collision_tag = Map.fetch!(attrs, :collision_tag)
    pointer_id = pointer_id_for(attrs)

    Multi.new()
    |> Multi.run(:existing, fn repo, _changes ->
      {:ok, repo.get(ConfigPointer, pointer_id)}
    end)
    |> Multi.run(:seed, fn repo, %{existing: existing} ->
      seed_branch(repo, existing, attrs, collision_tag)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{seed: result}} ->
        {:ok, result}

      # A concurrent seed won the pointer-insert race: this txn's object insert
      # was rolled back (no orphan) and the WINNER's pointer is now durable. Do
      # NOT blindly report `:exists` — the winner may have written a DIFFERENT
      # body (the two-plugins-one-name collision under concurrency). Re-run ONCE:
      # the pointer now exists, so the serial existing-pointer branch runs the
      # full body/source_turn_id comparison and returns the correct `:exists` /
      # `collision_tag`. Bounded to a single retry (the pointer is durable now).
      {:error, :seed, :seed_lost_race, _changes} when retry? ->
        do_seed_if_no_pointer(attrs, false)

      {:error, :seed, :seed_lost_race, _changes} ->
        {:ok, :exists}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # No pointer yet → insert the immutable object, then insert the pointer with
  # `on_conflict: :nothing` (a concurrent seed that won the race leaves the
  # existing pointer untouched and this txn's object is rolled back below).
  defp seed_branch(repo, nil, attrs, _collision_tag) do
    object_attrs = object_attrs(attrs)

    with {:ok, object} <- repo.insert(ConfigObject.changeset(object_attrs)),
         pointer_attrs = pointer_attrs(Map.put(attrs, :config_id, object.id)),
         {:ok, pointer} <-
           repo.insert(ConfigPointer.changeset(pointer_attrs),
             on_conflict: :nothing,
             conflict_target: :id
           ) do
      # `on_conflict: :nothing` returns a struct with a nil primary key when the
      # row already existed (a racing seed won) — roll back so we leave no orphan
      # object and report the existing pointer as authoritative.
      if is_nil(pointer.id) do
        {:error, :seed_lost_race}
      else
        {:ok, :seeded}
      end
    end
  end

  # Pointer already exists — three cases, distinguished by the pointed object's
  # body + `source_turn_id` (the seed's `source_turn_id` is DETERMINISTIC for a
  # given (ws, subject), so a SECOND seed of the same slot reproduces it, while a
  # CR-publish / repoint OVERRIDE carries a different one):
  #
  #   1. body == seed body                       → `:exists` (idempotent re-seed).
  #   2. body differs, SAME seed source_turn_id  → `collision_tag` (two plugins
  #      claimed the same seed slot with different bodies — fail loud).
  #   3. body differs, DIFFERENT source_turn_id  → `:exists` (a user/CR OVERRIDE
  #      owns the pointer — DO NOT clobber it; the override survives the re-seed).
  #
  # This makes the seed BOTH idempotent AND override-safe while still catching the
  # genuine two-plugins-one-name collision (SPEC §4.2).
  defp seed_branch(repo, %ConfigPointer{config_id: config_id}, attrs, collision_tag) do
    pointed = repo.get!(ConfigObject, config_id)
    # `pointed.body` is the WRITTEN body after a full JSON round-trip (the `:map`
    # field dumps via Jason on insert and loads as a string-keyed/-valued map).
    # `stringify_keys/1` only stringifies KEYS — scalar atom VALUES (e.g. a role
    # recipe's `requested_caps` `%{behavior: Mod, action: :read}`) stay atoms — so
    # the two diverged on every reboot and tripped the collision guard
    # (`{:role_seed_collision, _}`), breaking BEAM restart against a seeded DB.
    # Normalize the seed body through the SAME JSON round-trip so the comparison
    # is representation-agnostic; a genuinely different body still differs (the
    # collision guard below is preserved).
    seed_body = attrs |> Map.fetch!(:body) |> stringify_keys() |> json_normalize()
    seed_turn = Map.fetch!(attrs, :source_turn_id)

    cond do
      pointed.body == seed_body -> {:ok, :exists}
      pointed.source_turn_id == seed_turn -> {:error, collision_tag}
      true -> {:ok, :exists}
    end
  end

  defp pointer_id_for(attrs) do
    layer = attrs |> Map.fetch!(:layer) |> normalize_layer!()
    workspace_uri = attrs |> Map.fetch!(:workspace_uri) |> uri_string!()
    subject_uri = attrs |> Map.fetch!(:subject_uri) |> uri_string!()
    key = Map.fetch!(attrs, :key)
    ConfigPointer.id(layer, workspace_uri, subject_uri, key)
  end

  @doc """
  Three-state seed UPSERT primitive — the FULL boot-seed contract a
  reflow-carrying deploy needs, folding the hand-rolled resolve → hash-compare →
  seed-family-check → upgrade → retry-tolerance pattern (shipped independently in
  `Ezagent.Socialware.DefinitionRegistry.seed_builtin_definition/2` (#1235) and
  `Ezagent.Agent.RecipeRegistry.seed_role_if_absent/2` (#1240)) into ONE place.

  `seed_object_if_no_pointer/1` covers only the TWO states a first-boot DB holds
  (no pointer → seed; same body → no-op) plus the same-boot collision guard. This
  adds the missing THIRD state — the DB already holds an OLDER version of this
  exact seed (every reflow-carrying deploy) — resolving `(layer, workspace,
  subject, key)` and branching on FOUR states:

    1. NO pointer yet → atomic seed-once (delegates to the race-safe
       `seed_object_if_no_pointer/1`) → `{:ok, :seeded}`.
    2. pointer exists, SAME body (content-hash) → `{:ok, :exists}` (idempotent
       re-seed / reboot no-op).
    3. pointer exists, body DIFFERS, and the pointed object is UPGRADABLE (see
       `:seed_family_prefix`) → UPGRADE: append a new object + repoint under the
       caller's `:upgrade_source_turn_id` → `{:ok, :seeded}`. A retry that
       re-hits that unique turn id (a prior boot wrote it, then crashed before the
       retry) → `{:ok, :already_upgraded}` — the crash-restart idempotency #1235
       needs (the unique `(workspace, subject, key, source_turn_id)` index).
    4. pointer exists, body DIFFERS, NOT upgradable (a user/CR OVERRIDE owns the
       pointer) → `{:ok, :exists}` — the override SURVIVES the re-seed.

  UPGRADABILITY (`:seed_family_prefix`, the branch-3-vs-4 discriminator):

    * a STRING (e.g. `"role-seed"`) → OVERRIDE-SAFE: the pointed object is
      upgradable IFF its `source_turn_id` starts with that prefix (a first-seed
      `<prefix>:…` or a self-upgrade `<prefix>-upgrade:…` turn). A user/CR
      override carries a different prefix → branch 4 (preserve). This is the
      `RecipeRegistry` contract (role-as-data SPEC §4.2).
    * ABSENT / `nil` → ALWAYS-UPGRADE on a hash difference, regardless of the
      pointed object's provenance. This is the `DefinitionRegistry` §5.2 contract
      (the `builtin_seed_object?` provenance guard was deliberately deleted: an
      edited built-in manifest re-promotes purely on a content-hash difference).
      Branch 4 is dormant for this caller — an admin-edited system-ws definition
      is still re-promoted to the built-in on the next boot, unchanged from today.

  A SAME-BOOT two-plugins-one-name collision (two DIFFERENT plugins claim the same
  slot with different bodies in ONE boot) is NOT this primitive's concern: at the
  DB layer it is indistinguishable from a cross-version upgrade (both are "pointer
  exists, body differs, seed-family turn"). The caller that needs it keeps a
  per-boot registry (`RecipeRegistry`) and checks BEFORE calling here.

  `attrs` requires the `write_and_point/1` shape (`:layer, :workspace_uri,
  :subject_uri, :key, :body, :actor_uri`) plus:
    * `:source_turn_id` — the deterministic FIRST-seed turn (branch 1).
    * `:upgrade_source_turn_id` — the (hash-carrying, deterministic) UPGRADE turn
      the caller stamps on branch-3 repoints (its uniqueness makes the upgrade
      idempotent under the entrypoint retry loop).
    * `:collision_tag` — the loud term `seed_object_if_no_pointer/1` returns on a
      concurrent divergent-body seed race (branch 1 only).
    * `:seed_family_prefix` — optional; see UPGRADABILITY above.
  """
  @spec seed_object_upsert(map()) ::
          {:ok, :seeded | :exists | :already_upgraded} | {:error, term()}
  def seed_object_upsert(attrs) when is_map(attrs) do
    layer = attrs |> Map.fetch!(:layer) |> normalize_layer!()
    workspace = attrs |> Map.fetch!(:workspace_uri) |> uri_string!()
    subject = attrs |> Map.fetch!(:subject_uri) |> uri_string!()
    key = Map.fetch!(attrs, :key)

    # Hash the SAME stringified body `object_attrs/1` persists, so this matches
    # the pointed object's stored `content_hash` column regardless of atom-vs-JSON
    # representation (P0 §3.2 round-trip stability).
    new_hash = attrs |> Map.fetch!(:body) |> stringify_keys() |> ContentHash.of()
    prefix = Map.get(attrs, :seed_family_prefix)

    case resolve(layer, workspace, subject, key) do
      :none ->
        seed_object_if_no_pointer(attrs)

      {:ok, %ConfigObject{content_hash: ^new_hash}} ->
        {:ok, :exists}

      {:ok, %ConfigObject{source_turn_id: turn}} ->
        if upgradable?(turn, prefix) do
          upgrade_object(attrs)
        else
          {:ok, :exists}
        end
    end
  end

  # Branch-3-vs-4 discriminator: a nil prefix means always-upgrade on a hash
  # difference (DefinitionRegistry §5.2); a string prefix gates the upgrade on
  # seed-family provenance (RecipeRegistry override-safety §4.2).
  defp upgradable?(_turn, nil), do: true

  defp upgradable?(turn, prefix) when is_binary(turn) and is_binary(prefix),
    do: String.starts_with?(turn, prefix)

  defp upgradable?(_turn, _prefix), do: false

  # Append the new immutable object + repoint under the caller's deterministic,
  # hash-carrying upgrade turn id. A prior boot that already wrote this exact turn
  # id (then crashed before the retry) makes the object insert hit the unique
  # `(workspace, subject, key, source_turn_id)` index → report `:already_upgraded`
  # so the entrypoint retry loop is idempotent (#1235).
  defp upgrade_object(attrs) do
    attrs
    |> Map.put(:source_turn_id, Map.fetch!(attrs, :upgrade_source_turn_id))
    |> write_and_point()
    |> case do
      {:ok, _write_result} ->
        {:ok, :seeded}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :source_turn_id) do
          {:ok, :already_upgraded}
        else
          {:error, {:seed_upgrade_failed, errors}}
        end

      {:error, reason} ->
        {:error, {:seed_upgrade_failed, reason}}
    end
  end

  @doc """
  The reserved CR `source_turn_id` prefixes (`cr-stage:`, `cr-publish:`).
  """
  @spec reserved_turn_prefixes() :: [String.t()]
  def reserved_turn_prefixes, do: @reserved_turn_prefixes

  @doc """
  True if `turn_id` carries a RESERVED CR prefix (`cr-stage:`/`cr-publish:`).

  Every NON-CR config-write/repoint entry that accepts a caller-supplied
  `turn_id` (`ConfigEvolve.apply_config_delta`, the `Agent.Config` facade)
  calls this and REJECTS a reserved prefix BEFORE any side effect / idempotency
  early-return — so a caller cannot pass a `cr-stage:` turn_id to the normal
  path and spoof an early-return / settled-turn marker.
  """
  @spec reserved_turn_prefix?(term()) :: boolean()
  def reserved_turn_prefix?(turn_id) when is_binary(turn_id) do
    Enum.any?(@reserved_turn_prefixes, &String.starts_with?(turn_id, &1))
  end

  def reserved_turn_prefix?(_), do: false

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

  @doc """
  List distinct config keys that currently have a pointer for `agent_uri`.

  This is intentionally pointer-derived, not schema-derived: current config
  evolution has no fixed key registry. Console callers should union this with
  their built-in/default keys.
  """
  @spec list_keys_for_subject(URI.t() | String.t()) :: [String.t()]
  def list_keys_for_subject(subject_uri) do
    subject = uri_string!(subject_uri)

    Repo.all(
      from(p in ConfigPointer,
        where: p.subject_uri == ^subject,
        distinct: true,
        select: p.key,
        order_by: p.key
      )
    )
  end

  @doc """
  List currently-pointed objects for a layer/key across workspaces.

  This follows current pointers, so retained immutable historical object
  versions are not included in catalog/discovery reads.
  """
  @spec list_current_objects(atom() | String.t(), String.t()) :: [ConfigObject.t()]
  def list_current_objects(layer, key) when is_binary(key) do
    layer = normalize_layer!(layer)

    Repo.all(
      from(p in ConfigPointer,
        join: o in ConfigObject,
        on: o.id == p.config_id,
        where: p.layer == ^layer and p.key == ^key,
        order_by: [asc: p.workspace_uri, asc: p.subject_uri],
        select: o
      )
    )
  end

  @doc """
  Read all currently-pointed layer objects for a subject/key.

  Returns entries keyed by canonical layer string (`"workspace"`, `"user"`,
  `"session"`). Missing layers are absent from the returned map.
  """
  @spec layer_objects_for_key(URI.t() | String.t(), String.t()) :: %{
          optional(String.t()) => pointer_with_object()
        }
  def layer_objects_for_key(subject_uri, key) when is_binary(key) do
    subject = uri_string!(subject_uri)

    Repo.all(
      from(p in ConfigPointer,
        join: o in ConfigObject,
        on: o.id == p.config_id,
        where: p.subject_uri == ^subject and p.key == ^key,
        select: {p.layer, p, o}
      )
    )
    |> Map.new(fn {layer, pointer, object} ->
      {layer, %{pointer: pointer, object: object}}
    end)
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

  Used by `Ezagent.ActionSet.ConfigEvolve`'s step-2 projection + boot
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

  Used by `Ezagent.ActionSet.ConfigEvolve` to make `apply_config_delta`
  idempotent on BOTH the serial pre-check AND the unique-constraint conflict
  path: re-dispatching ANY already-applied turn (current OR superseded) returns
  that turn's historical object id (a string) instead of minting a new object —
  satisfying the `config_id: :string` action contract. Lookup is by
  `source_turn_id` alone; the DB unique index `(workspace, subject, key,
  source_turn_id)` is tuple-scoped, but the production invariant (one settled
  Turn → one `config_delta` → one `(subject, key)`, self-bound in ConfigEvolve)
  means a `source_turn_id` maps to a single object, so `limit: 1` is unambiguous.
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
    # Hash the SAME stringified body that gets persisted, so the stored column,
    # a later DB-read hash, and a fresh `Definition.content_hash/1` all coincide
    # (P0 §3.2 round-trip stability).
    body = attrs |> Map.fetch!(:body) |> stringify_keys()

    %{
      id: Map.get(attrs, :id) || Ecto.UUID.generate(),
      workspace_uri: attrs |> Map.fetch!(:workspace_uri) |> uri_string!(),
      subject_uri: attrs |> Map.fetch!(:subject_uri) |> uri_string!(),
      key: Map.fetch!(attrs, :key),
      body: body,
      content_hash: Map.get(attrs, :content_hash) || Ezagent.Socialware.ContentHash.of(body),
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

  # Round-trip a string-keyed body through Jason so atom VALUES become the same
  # strings Ecto's `:map` field stores them as on insert — making the seed-body
  # comparison in `seed_branch/4` representation-agnostic (atom vs JSON string).
  defp json_normalize(map) when is_map(map) do
    map |> Jason.encode!() |> Jason.decode!()
  end

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
