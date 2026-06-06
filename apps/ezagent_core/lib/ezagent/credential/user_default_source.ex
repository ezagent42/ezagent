defmodule Ezagent.Credential.UserDefaultSource do
  @moduledoc """
  The user's default credential source per (owner, workspace, flavor) — the §5.2
  source-of-truth POINTER (not a naming convention). The pointed source is validated to
  be in the same workspace, owned by the same user, of the right flavor, and to exist.

  ## Authorized write path

  `persist_validated/5` is the action BODY — VALIDATION + persist only. It is NOT a
  public unauthenticated setter, and its name reflects that: it does NOT authorize. The
  AUTHORIZED entry point is the cap-checked Behavior action `:set_default_credential_source`
  (`Ezagent.Behavior.UserDefaultCredentialSource`, registered on the User Kind),
  dispatched via `Ezagent.Router`, which performs the cap-check AND emits the audit row
  (the `{:emit, ...}` effect) automatically — mirroring `Ezagent.Behavior.WorkspaceUserAdmin`
  `:create_user`.

  ### Single-caller invariant (structural, codex H2)

  `persist_validated/5` has exactly ONE lib call-site: the
  `Ezagent.Behavior.UserDefaultCredentialSource` handler. The adoption migration reaches
  it the same way — through `set_via_dispatch/3` → `Ezagent.Router.dispatch` → that
  handler. There is NO other in-VM mutator on this store (no public cap-less setter). The
  grep invariant test `Ezagent.Invariants.UserDefaultSourceSingleWriterTest` HARD-fails
  CI if any lib module other than that Behavior calls `persist_validated`, mirroring
  `Ezagent.Invariants.SingleSpawnEntryTest`. Tests may call it directly to exercise the
  validation logic in isolation (the gate scans `*.ex` only).

  Queried via `Ezagent.UriQuery` (`:user_default_credential_source`) and by
  `pick_credential_source` in PR-1.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "user_default_credential_sources" do
    field(:owner_uri, :string)
    field(:workspace_uri, :string)
    field(:flavor, :string)
    field(:source_uri, :string)
    field(:set_by, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  defp id(owner, ws, flavor), do: "#{owner}|#{ws}|#{flavor}"

  @doc """
  Action BODY for setting the default source — VALIDATION + persist only, NO auth. The
  name says it: this persists an already-authorized request; it does NOT authorize. See
  the moduledoc for why this is NOT a public setter (the cap-check + audit live in the
  dispatched Behavior action) and the single-caller invariant. `set_by` defaults to
  `owner`; the dispatched action passes the real caller.

  Validation (all required, fail loud):
    1. source parses + exists (durable snapshot) — else `{:error, :source_not_found}`;
    2. source's workspace == `ws` — else `{:error, :source_workspace_mismatch}`;
    3. source belongs to `owner` (spawn lineage) — else `{:error, :source_owner_mismatch}`;
    4. source's flavor == `flavor` (`UriQuery.resolve(:flavor, source)`) — else
       `{:error, :source_flavor_mismatch}`.
  """
  @spec persist_validated(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def persist_validated(owner, ws, flavor, source_uri, set_by \\ nil) do
    with {:ok, source} <- Ezagent.URI.parse(source_uri),
         :ok <- validate_source(source, owner, ws, flavor) do
      %__MODULE__{}
      |> cast(
        %{
          id: id(owner, ws, flavor),
          owner_uri: owner,
          workspace_uri: ws,
          flavor: flavor,
          source_uri: source_uri,
          set_by: set_by || owner
        },
        [:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by]
      )
      |> validate_required([:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by])
      |> Repo.insert(
        on_conflict: {:replace, [:source_uri, :set_by, :updated_at]},
        conflict_target: :id
      )
    end
  end

  @doc """
  The AUTHORIZED write path — dispatch the `:set_default_credential_source` Behavior
  action on the OWNER's User Kind. Dispatch performs the cap-check (step 5.5) + audit
  (the `{:emit, ...}` effect); the action body runs `set/5`. This is the single
  chokepoint both interactive use and the adoption migration (Task 5) route through.

  `owner_uri` is the User Kind being targeted; `args` carries `%{flavor, source_uri,
  workspace}`; `ctx` carries `%{caller, caps}` (the principal whose authority is
  checked).
  """
  @spec set_via_dispatch(URI.t() | String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def set_via_dispatch(owner_uri, args, ctx) when is_map(args) and is_map(ctx) do
    owner =
      case owner_uri do
        %URI{} = u -> u
        s when is_binary(s) -> Ezagent.URI.new!(s)
      end

    target =
      Ezagent.URI.with_action(
        owner,
        :user_default_credential_source,
        :set_default_credential_source
      )

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    cmd =
      Ezagent.Cmd.new(
        target,
        :set_default_credential_source,
        Map.put(args, :owner_uri, URI.to_string(owner)),
        %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
      )

    Ezagent.Router.dispatch(cmd)
  end

  @doc "Resolve the source URI, or nil if unset (caller falls through to workspace-shared)."
  @spec resolve(String.t(), String.t(), String.t()) :: String.t() | nil
  def resolve(owner, ws, flavor) do
    case Repo.get(__MODULE__, id(owner, ws, flavor)) do
      %__MODULE__{source_uri: s} -> s
      nil -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Validation (checks 1-4) — :ok | {:error, reason}
  # ---------------------------------------------------------------------------

  defp validate_source(%URI{} = source, owner, ws, flavor) do
    with :ok <- validate_source_exists(source),
         :ok <- validate_source_workspace(source, ws),
         :ok <- validate_source_owner(source, owner),
         :ok <- validate_source_flavor(source, flavor) do
      :ok
    end
  end

  # 1. existence — durable snapshot row (independent of running pid).
  defp validate_source_exists(%URI{} = source) do
    if match?({:ok, _}, Ezagent.SnapshotStore.latest(source)) do
      :ok
    else
      {:error, :source_not_found}
    end
  end

  # 2. workspace — the pointed source's workspace segment must equal `ws`. Uses the
  # canonical URI accessor, NOT string parsing.
  defp validate_source_workspace(%URI{} = source, ws) do
    if Ezagent.URI.workspace_name!(source) == ws do
      :ok
    else
      {:error, :source_workspace_mismatch}
    end
  end

  # 3. owner — the source agent must belong to `owner`. The durable owner signal in
  # core is the spawn lineage (`spawned_by`), which for a base/`<user>-default` agent is
  # the owning user. (Deviation noted in PR report: core has no dedicated owner attr; the
  # lineage spawned_by is the available durable owner signal.)
  defp validate_source_owner(%URI{} = source, owner) do
    case Ezagent.AgentLineage.lookup(source) do
      {:ok, %URI{} = spawned_by} ->
        if URI.to_string(spawned_by) == owner, do: :ok, else: {:error, :source_owner_mismatch}

      :error ->
        {:error, :source_owner_mismatch}
    end
  end

  # 4. flavor — the source's stored flavor must equal `flavor`.
  defp validate_source_flavor(%URI{} = source, flavor) do
    case Ezagent.UriQuery.resolve(:flavor, source) do
      {:ok, ^flavor} -> :ok
      {:ok, _other} -> {:error, :source_flavor_mismatch}
      :none -> {:error, :source_flavor_mismatch}
      {:error, _} -> {:error, :source_flavor_mismatch}
    end
  end
end
