defmodule Ezagent.Capability.Scope do
  @moduledoc false

  alias Ezagent.Capability

  @doc """
  Arity-1 structural cross-workspace test (SPEC v3 §5.1): a cap is
  cross-workspace iff its `workspace_uri` is `:any`. Backs
  `Ezagent.Capability.cross_workspace?/1` for call sites without a caller
  URI in hand; new code prefers `/2`, which also honors the membership bypass.
  """
  @spec cross_workspace?(Capability.t()) :: boolean()
  def cross_workspace?(%Capability{workspace_uri: :any}), do: true
  def cross_workspace?(%Capability{}), do: false

  @doc """
  Arity-2 cross-workspace test (SPEC v3 §13.3, Keycloak realm-admin model):
  true in ANY of THREE cases — (1) the cap is structurally cross-workspace
  (`workspace_uri: :any`); (2) the caller's HOME workspace is structurally
  `workspace://system` (`home_is_system?/1` — the `entity://system/…` admin
  shape); or (3) the caller is listed in `workspace://system`'s members
  (`member_of_system?/1`). Cases (2)/(3) grant the bypass by structural home /
  membership, NOT by an explicit `:any` grant on the cap. Case (1) holds for
  ANY caller value (the `workspace_uri: :any` clause ignores the caller); only
  for a concrete cap does a non-`%URI{}` caller disable cases (2)/(3) and yield
  `false`. Backs `Ezagent.Capability.cross_workspace?/2`; consumed by
  `Kind.Runtime` step 5.6 to decide whether to override workspace isolation.
  """
  @spec cross_workspace?(Capability.t(), URI.t() | :vm_internal | nil) :: boolean()
  def cross_workspace?(%Capability{workspace_uri: :any}, _caller_uri), do: true

  def cross_workspace?(%Capability{}, %URI{} = caller_uri) do
    home_is_system?(caller_uri) or member_of_system?(caller_uri)
  end

  def cross_workspace?(%Capability{}, _), do: false

  @doc """
  True iff the caller's HOME workspace IS `workspace://system` — the
  structural admin URI shape (`entity://system/<type>/<name>`). The inner
  `workspace_of_caller_safe/1` rescues a malformed-URI raise to `false`
  (deny-by-default). Backs `Ezagent.Capability.home_is_system?/1`.
  """
  @spec home_is_system?(URI.t()) :: boolean()
  def home_is_system?(%URI{} = caller_uri) do
    case workspace_of_caller_safe(caller_uri) do
      %URI{} = workspace -> Ezagent.URI.name?(workspace, :system)
      _ -> false
    end
  end

  def home_is_system?(_), do: false

  @doc """
  True iff the caller is listed in `workspace://system`'s `members` (SPEC v2
  PR-D "Promote to system" — cross-workspace authority by MEMBERSHIP, so a
  regular `entity://<ws>/<type>/<name>` becomes admin-equivalent without a
  special URI host). Lazy `apply/3` lookup of `Ezagent.Workspace.Store` avoids
  a compile-time `ezagent_core → ezagent_domain_workspace` cycle; an unloaded
  store → `false` (deny-by-default). Backs `Ezagent.Capability.member_of_system?/1`.
  """
  @spec member_of_system?(URI.t()) :: boolean()
  def member_of_system?(%URI{} = caller_uri) do
    if Code.ensure_loaded?(Ezagent.Workspace.Store) and
         function_exported?(Ezagent.Workspace.Store, :get_by_name, 1) do
      case apply(Ezagent.Workspace.Store, :get_by_name, ["system"]) do
        %{members: members} when is_list(members) ->
          caller_str = URI.to_string(caller_uri)
          Enum.any?(members, fn m -> URI.to_string(m) == caller_str end)

        _ ->
          false
      end
    else
      false
    end
  end

  def member_of_system?(_), do: false

  @doc """
  Derive a target URI's workspace scope — a `%URI{}` for per-tenant schemes,
  or `:any` for cross-cutting schemes (`system://` etc.) where the workspace
  boundary doesn't apply. Thin alias over `Ezagent.URI.workspace_of/1`; backs
  `Ezagent.Capability.workspace_of/1` (SPEC v3 §4.2 / §5.3).
  """
  @spec workspace_of(URI.t()) :: URI.t() | :any
  def workspace_of(%URI{} = uri), do: Ezagent.URI.workspace_of(uri)

  defp workspace_of_caller_safe(%URI{} = uri) do
    try do
      workspace_of(uri)
    rescue
      _ -> :any
    end
  end
end
