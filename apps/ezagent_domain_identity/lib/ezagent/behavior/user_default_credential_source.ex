defmodule Ezagent.ActionSet.UserDefaultCredentialSource do
  @moduledoc """
  #17 cascade PR-0 (spec §5.2) — the cap-checked, audited chokepoint for writing a
  user's default credential source pointer.

  ## Why a separate Behavior (own cap subject)

  Same rationale as `Ezagent.ActionSet.WorkspaceUserAdmin`: the Capability struct's
  action axis is not always enforced at the cap level, so each privileged action gets
  its OWN Behavior + cap subject. `:set_default_credential_source` is registered on the
  User Kind with the distinct cap:

      Capability.cap(:user, __MODULE__, :set_default_credential_source)

  The OWNER holds this cap on their own User Kind (it is part of their structural
  baseline / can be granted by a workspace admin); a stranger does not, so the dispatch
  layer denies them with `:unauthorized`. This is the SOLE write path for the pointer:
  the cross-source validations (exists / same workspace / same owner / same flavor) AND
  the `EzagentCore.Repo.insert` against the core-owned `user_default_credential_sources`
  table BOTH live in THIS handler — there is NO exported cap-less mutator in core
  (`Ezagent.Credential.UserDefaultSource` keeps only the schema, `resolve/3`, a pure
  `changeset/2` builder, and the dispatch helper `set_via_dispatch/3`). This mirrors how
  `Ezagent.ActionSet.ExternalMirror` does the cross-app `Repo.insert` on the core-owned
  `Ezagent.ExternalMirror.BindingRow` schema. Because the persistence is structurally
  coupled to this cap-checked + audited dispatch handler, an in-VM caller cannot write a
  victim's pointer. That single-writer invariant is enforced structurally by
  `Ezagent.Invariants.UserDefaultSourceSingleWriterTest`.

  ## Action

  - `:set_default_credential_source` — args `%{flavor, source_uri, workspace,
    owner_uri?}` → `%{flavor, source_uri}`. The cap-check runs in dispatch step 5.5;
    the `{:emit, ...}` effect records the audit row.

  ## Slice

      %{set_count: integer()}

  Incidental counter; the durable pointer is the `user_default_credential_sources`
  table owned by `Ezagent.Credential.UserDefaultSource`.
  """

  use Ezagent.Lifecycle

  alias Ezagent.Credential.UserDefaultSource
  alias EzagentCore.Repo

  action(:set_default_credential_source,
    args: %{
      flavor: :string,
      source_uri: :string,
      workspace: :string,
      owner_uri: {:option, :string},
      expected_source_uri: {:option, :string}
    },
    returns: %{
      flavor: :string,
      source_uri: :string
    },
    caps: [{:set_default_credential_source, kind: :user}],
    modes: [:call],
    description:
      "Set the calling user's default credential source for a flavor. Validates the " <>
        "pointed source exists, is in the same workspace, is owned by the user, and " <>
        "is the right flavor. Own cap subject (distinct from Identity actions)."
  )

  def required_caps do
    %{
      set_default_credential_source:
        Ezagent.Capability.cap(:user, __MODULE__, :set_default_credential_source)
    }
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{set_count: 0}}

  # Workspace-scoped, workspace-admin grantable (owner also holds it on self).
  def data_owner(_), do: :any

  def handle_set_default_credential_source(args, ctx) when is_map(args) do
    flavor = Map.get(args, :flavor)
    source_uri = Map.get(args, :source_uri)
    workspace = Map.get(args, :workspace)
    expected_source_uri = Map.get(args, :expected_source_uri)
    expected_source? = Map.has_key?(args, :expected_source_uri)
    # The owner is DERIVED from the dispatched target (`ctx.self_uri`) — the User Kind
    # this action was cap-checked against (runtime step 5.5). It is NEVER read from args:
    # the caller's authorization is bound to the target URI, so trusting an args-supplied
    # `owner_uri` would let a caller authorized for X write victim Y's pointer (codex H1).
    # A back-compat `owner_uri` arg may still be present (set by `set_via_dispatch/3`),
    # but ANY value that does not exactly match the ctx self URI is REJECTED — never
    # silently coerced — so the field can only ever echo the real target.
    owner = self_uri_str(ctx)
    set_by = caller_str(ctx) || owner

    with :ok <- check_owner_arg(Map.get(args, :owner_uri), owner),
         true <- is_binary(flavor) and is_binary(source_uri) and is_binary(workspace),
         {:ok, _row} <-
           persist_validated(
             owner,
             workspace,
             flavor,
             source_uri,
             set_by,
             expected_source?,
             expected_source_uri
           ) do
      cur = ctx[:read].(:set_count, 0)

      {:ok, %{flavor: flavor, source_uri: source_uri},
       [
         {:set, :set_count, cur + 1},
         {:emit, :default_credential_source_set,
          %{
            owner_uri: owner,
            workspace_uri: workspace,
            flavor: flavor,
            source_uri: source_uri,
            set_by: set_by,
            at: DateTime.utc_now()
          }}
       ]}
    else
      false ->
        {:error,
         {:bad_args, "set_default_credential_source requires {flavor, source_uri, workspace}"}}

      {:error, _} = err ->
        err
    end
  end

  def handle_set_default_credential_source(args, _ctx) do
    {:error, {:bad_args, "set_default_credential_source requires a map", args}}
  end

  # The owner is always the dispatched target. An `owner_uri` arg is tolerated ONLY when
  # it exactly equals that target (the shape `set_via_dispatch/3` produces); any other
  # value is a tampering attempt and is rejected loud (let-it-crash: no silent coercion).
  defp check_owner_arg(nil, _self_uri), do: :ok
  defp check_owner_arg(self_uri, self_uri), do: :ok
  defp check_owner_arg(other, _self_uri), do: {:error, {:owner_uri_mismatch, other}}

  defp self_uri_str(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp caller_str(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Validate-and-persist — the action BODY, now LIVING INSIDE the cap-checked +
  # audited handler (codex H2). There is NO exported cap-less writer in core: the
  # cross-source validations AND the cross-app `EzagentCore.Repo.insert` against the
  # core-owned `user_default_credential_sources` table both run here, structurally
  # coupled to the dispatch chokepoint — exactly like `Ezagent.ActionSet.ExternalMirror`
  # writes the core-owned `Ezagent.ExternalMirror.BindingRow`. The core store provides
  # only the PURE `changeset/2` builder (no Repo write of its own).
  #
  # Validation (all required, fail loud):
  #   1. source parses + exists (durable snapshot) — else {:error, :source_not_found};
  #   2. source's workspace == ws        — else {:error, :source_workspace_mismatch};
  #   3. source belongs to owner (spawn lineage) — else {:error, :source_owner_mismatch};
  #   4. source's flavor == flavor        — else {:error, :source_flavor_mismatch}.
  defp persist_validated(
         owner,
         ws,
         flavor,
         source_uri,
         set_by,
         expected_source?,
         expected_source_uri
       ) do
    with_default_source_lock(owner, ws, flavor, fn ->
      with {:ok, source} <- Ezagent.URI.parse(source_uri),
           :ok <- validate_source(source, owner, ws, flavor),
           :ok <-
             require_expected_source(
               owner,
               ws,
               flavor,
               expected_source?,
               expected_source_uri
             ) do
        %{owner_uri: owner, workspace_uri: ws, flavor: flavor, source_uri: source_uri}
        |> UserDefaultSource.changeset(set_by || owner)
        |> Repo.insert(
          on_conflict: {:replace, [:source_uri, :set_by, :updated_at]},
          conflict_target: :id
        )
      end
    end)
  end

  defp require_expected_source(_owner, _ws, _flavor, false, _expected), do: :ok

  defp require_expected_source(owner, ws, flavor, true, expected) do
    if UserDefaultSource.resolve(owner, ws, flavor) == expected do
      :ok
    else
      {:error, :default_source_changed}
    end
  end

  defp with_default_source_lock(owner, workspace, flavor, fun) do
    resource = {__MODULE__, :default_credential_source, owner, workspace, flavor}
    :global.trans({resource, self()}, fun)
  end

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
  # the owning user.
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
