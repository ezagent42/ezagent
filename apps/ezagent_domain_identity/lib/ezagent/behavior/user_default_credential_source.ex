defmodule Ezagent.Behavior.UserDefaultCredentialSource do
  @moduledoc """
  #17 cascade PR-0 (spec §5.2) — the cap-checked, audited chokepoint for writing a
  user's default credential source pointer.

  ## Why a separate Behavior (own cap subject)

  Same rationale as `Ezagent.Behavior.WorkspaceUserAdmin`: the Capability struct's
  action axis is not always enforced at the cap level, so each privileged action gets
  its OWN Behavior + cap subject. `:set_default_credential_source` is registered on the
  User Kind with the distinct cap:

      Capability.cap(:user, __MODULE__, :set_default_credential_source)

  The OWNER holds this cap on their own User Kind (it is part of their structural
  baseline / can be granted by a workspace admin); a stranger does not, so the dispatch
  layer denies them with `:unauthorized`. This is the SOLE public write path for the
  pointer — `Ezagent.Credential.UserDefaultSource.persist_validated/5` is the
  validation+persist body (NO auth in it), reachable ONLY from this handler (and the
  adoption action, which also dispatches here). That single-caller invariant is enforced
  structurally by `Ezagent.Invariants.UserDefaultSourceSingleWriterTest`.

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

  action(:set_default_credential_source,
    args: %{
      flavor: :string,
      source_uri: :string,
      workspace: :string,
      owner_uri: {:option, :string}
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
           UserDefaultSource.persist_validated(owner, workspace, flavor, source_uri, set_by) do
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
end
