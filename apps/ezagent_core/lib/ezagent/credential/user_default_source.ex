defmodule Ezagent.Credential.UserDefaultSource do
  @moduledoc """
  The user's default credential source per (owner, workspace, flavor) — the §5.2
  source-of-truth POINTER (not a naming convention). The pointed source is validated to
  be in the same workspace, owned by the same user, of the right flavor, and to exist.

  ## This module holds NO writer (codex H2)

  There is deliberately **no exported cap-less mutator** here. This module is a pure
  data + read module:

    * the Ecto schema/struct for `user_default_credential_sources`;
    * `resolve/3` — the read path (returns the source URI or `nil`);
    * `changeset/2` — a PURE changeset builder (NOT a writer — it never touches the
      Repo; it just casts + validates the field shape);
    * `set_via_dispatch/3` — a thin convenience that DISPATCHES the cap-checked
      Behavior action (it performs no validation and no `Repo` write itself).

  The validation (source exists / same workspace / same owner / same flavor) AND the
  `EzagentCore.Repo.insert` BOTH live inside the cap-checked, audited Behavior
  `Ezagent.ActionSet.UserDefaultCredentialSource` (`:set_default_credential_source`,
  registered on the User Kind), structurally coupled to the dispatch chokepoint —
  exactly mirroring how `Ezagent.ActionSet.ExternalMirror` does the cross-app
  `Repo.insert` on the core-owned `Ezagent.ExternalMirror.BindingRow` schema. Because
  no public writer exists in core, an in-VM caller cannot persist a pointer for a victim
  `owner` without going through the cap-check + the `ctx.self_uri` owner-derivation (the
  H1 fix) + the `{:emit, :default_credential_source_set, ...}` audit.

  ### Single-writer invariant (structural, codex H2)

  `Ezagent.Invariants.UserDefaultSourceSingleWriterTest` HARD-fails CI if any module
  other than that Behavior issues a `Repo.insert`/`Repo.update`/`Repo.delete` against
  this schema or the `user_default_credential_sources` table — so "I'll just persist a
  default source directly for my new feature" drift is impossible without a conscious
  test edit.

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

  @doc """
  Build the deterministic primary key for a `(owner, workspace, flavor)` triple. The
  pointer is unique per triple — re-setting upserts on this key.
  """
  @spec id(String.t(), String.t(), String.t()) :: String.t()
  def id(owner, ws, flavor), do: "#{owner}|#{ws}|#{flavor}"

  @doc """
  PURE changeset builder for the pointer row — NO authorization, NO validation of the
  pointed source, and crucially **NO `Repo` write**. A changeset builder is not a
  writer; this only casts the supplied fields and asserts they are present so the
  cap-checked Behavior (the SOLE persister) can `Repo.insert` it.

  The cross-source validations (exists / workspace / owner / flavor) and the actual
  `EzagentCore.Repo.insert` live in `Ezagent.ActionSet.UserDefaultCredentialSource`,
  under the dispatch chokepoint — see the moduledoc.
  """
  @spec changeset(map(), String.t() | nil) :: Ecto.Changeset.t()
  def changeset(%{owner_uri: owner, workspace_uri: ws, flavor: flavor} = attrs, set_by \\ nil) do
    %__MODULE__{}
    |> cast(
      %{
        id: id(owner, ws, flavor),
        owner_uri: owner,
        workspace_uri: ws,
        flavor: flavor,
        source_uri: Map.get(attrs, :source_uri),
        set_by: set_by || owner
      },
      [:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by]
    )
    |> validate_required([:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by])
  end

  @doc """
  The AUTHORIZED write path — dispatch the `:set_default_credential_source` Behavior
  action on the OWNER's User Kind. Dispatch performs the cap-check (step 5.5) + audit
  (the `{:emit, ...}` effect); the action body runs the validations + the `Repo.insert`.
  This is the single chokepoint both interactive use and the adoption migration (Task 5)
  route through.

  This helper performs NO validation and NO `Repo` write itself — it only constructs the
  command and hands it to `Ezagent.Router.dispatch/1`.

  `owner_uri` is the User Kind being targeted; `args` carries `%{flavor, source_uri,
  workspace}`; `ctx` carries `%{caller, authenticated_principal, caps}`. The
  authenticated principal is forwarded explicitly and is never inferred from the
  machinery caller.
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
    authenticated_principal = Map.fetch!(ctx, :authenticated_principal)
    caps = Map.fetch!(ctx, :caps)
    owner_uri_string = URI.to_string(owner)

    cmd =
      Ezagent.Cmd.new(
        target,
        :set_default_credential_source,
        Map.put(args, :owner_uri, owner_uri_string),
        %{
          mode: :call,
          caller: caller,
          authenticated_principal: authenticated_principal,
          caps: caps,
          reply: {:caller_inbox, self()}
        }
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
end
