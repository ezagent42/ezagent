defmodule Ezagent.Workspace.UserReads do
  @moduledoc """
  The single caller-authorizing read chokepoint for a workspace's USER
  roster — the `Ezagent.Users.list_in_workspace/1` enumeration of every
  provisioned user in a workspace (read-plane PR-4 rework).

  ## Why this exists

  Workspace user-list reads were caller-less: any presenter that could
  name a workspace enumerated EVERY provisioned user in it — including
  their account/security metadata (email, password presence,
  confirmation, disablement). `UserReads` is the user-plane twin of
  `Ezagent.Workspace.WorkspaceReads` (the session/agent list
  chokepoint): every principal-facing workspace user-LIST read routes
  through here, is authorized FIRST, and only then touches the listing.

  ## Contract (binding)

  `users/2` takes `caller` FIRST and authorizes BEFORE any read:

    1. WORKSPACE authorization — REUSED from
       `Ezagent.Workspace.WorkspaceReads.authorized_workspace?/2` (the
       one workspace gate; a security boundary must not be copy-pasted).
    2. ROSTER authorization — the caller must ALSO be a DECLARED member
       of the workspace (`WorkspaceReads.declared_member?/2`) OR an
       operator (`Ezagent.Identity.AdminAuthority.admin?/2`, the same
       promoted-operator-aware predicate `OperatorReads` uses). A
       cap-scoped non-member gets NO roster (the F2 class of bug).
    3. Fail-closed — a nil/malformed/unauthorized caller, a
       non-workspace scope, or an unavailable user-listing facade all
       return `[]`.

  ## Per-row sensitive metadata (F4)

  The roster (URI + display name) is legitimately visible to workspace
  members; another user's ACCOUNT/SECURITY metadata is not.
  `reveal_metadata?/2` is the ONE predicate for that per-row decision —
  the caller IS that user, or the caller is an operator — so presenters
  (`Ezagent.World.UserData`) render another user's email /
  password-presence / confirmation / disablement fields ONLY when it
  holds. Rows must render those fields as undisclosed (`nil`), never as
  a negated value (`false` would assert "not disabled" — itself a
  leak).

  ## Dependency direction (runtime DI)

  Same shape as `WorkspaceReads`: `Ezagent.Users` sits BELOW this domain
  (a declared dep of `ezagent_domain_workspace`), so the DI indirection
  is NOT cycle-breaking — it gives tests the same fake-facade seam as
  `WorkspaceReads`' `agent_listing_facade/0` and keeps the fail-closed
  shape identical.
  """

  alias Ezagent.Identity.AdminAuthority
  alias Ezagent.Workspace.WorkspaceReads

  @doc """
  Authorized workspace user roster for `caller` in `workspace_uri`.

  Returns the provisioned users of the workspace as decoded
  `Ezagent.Users` rows (`%{uri: URI.t(), ...}`) in the base listing's
  order. Fail-closed: `[]` for a nil/malformed/unauthorized caller, a
  non-workspace scope, or an unavailable user-listing facade.
  """
  @spec users(URI.t() | term(), URI.t() | term()) :: [map()]
  def users(caller, workspace_uri)

  def users(%URI{} = caller, %URI{scheme: "workspace"} = workspace_uri) do
    with :ok <- authorize_roster(caller, workspace_uri),
         {:ok, scoped} <- workspace_scoped_users(workspace_uri) do
      scoped
    else
      _ -> []
    end
  end

  def users(_caller, _workspace_uri), do: []

  @doc """
  May `caller` see `user_uri`'s account/security metadata (email,
  password presence, confirmation, disablement)?

  True iff the caller IS `user_uri` or is an operator per
  `Ezagent.Identity.AdminAuthority.admin?/2` (caps loaded LIVE so a
  fresh promotion/demotion is seen immediately). The ONE per-row
  metadata predicate for the user plane — never re-derived in a
  presenter.
  """
  @spec reveal_metadata?(URI.t() | term(), URI.t() | term()) :: boolean()
  def reveal_metadata?(%URI{} = caller, %URI{} = user_uri) do
    URI.to_string(caller) == URI.to_string(user_uri) or AdminAuthority.admin?(caller)
  end

  def reveal_metadata?(_caller, _user_uri), do: false

  # ----- roster authorization (BEFORE any read) -----------------------

  defp authorize_roster(%URI{} = caller, %URI{} = workspace_uri) do
    if WorkspaceReads.authorized_workspace?(caller, workspace_uri) and
         (WorkspaceReads.declared_member?(caller, workspace_uri) or
            AdminAuthority.admin?(caller)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  # ----- workspace-scoped base listing (runtime DI — see moduledoc) ---

  defp workspace_scoped_users(%URI{} = workspace_uri) do
    facade = user_listing_facade()

    if Code.ensure_loaded?(facade) and function_exported?(facade, :list_in_workspace, 1) do
      {:ok, facade.list_in_workspace(workspace_uri)}
    else
      {:error, {:user_listing_unavailable, facade}}
    end
  end

  defp user_listing_facade do
    Application.get_env(
      :ezagent_domain_workspace,
      :user_listing_facade,
      Ezagent.Users
    )
  end
end
