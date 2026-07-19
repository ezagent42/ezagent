defmodule Ezagent.Session.TemplateReads do
  @moduledoc """
  The single caller-authorizing read chokepoint for a workspace's
  SESSION-TEMPLATE list — the union of the LIVE template Kinds
  (`Ezagent.KindRegistry.list_all/0`, global) and the DURABLE template
  snapshots (`Ezagent.Ecto.KindSnapshot.list_all/0`, global) filtered to
  one workspace (read-plane PR-4 rework).

  ## Why this exists

  Workspace session-template list reads were caller-less global scans:
  any presenter that could name a workspace enumerated every live and
  persisted session template in it. `TemplateReads` is the
  template-plane twin of `Ezagent.Workspace.WorkspaceReads`: every
  principal-facing workspace template-LIST read routes through here, is
  authorized FIRST, and only then touches the global enumerations
  (scoped down to the workspace per row).

  ## Contract (binding)

  `session_templates/2` takes `caller` FIRST and authorizes BEFORE any
  read:

    1. WORKSPACE authorization — REUSED from
       `Ezagent.Workspace.WorkspaceReads.authorized_workspace?/2` (the
       one workspace gate; a security boundary must not be copy-pasted).
    2. ROSTER authorization — templates are a workspace's shared
       resource: the caller must ALSO be a DECLARED member of the
       workspace (`WorkspaceReads.declared_member?/2`) OR an operator
       (`Ezagent.Identity.AdminAuthority.admin?/2`, the same
       promoted-operator-aware predicate `OperatorReads` uses). A
       cap-scoped non-member gets NO template list (the F2 class of
       bug).
    3. Fail-closed — a nil/malformed/unauthorized caller or an
       unavailable REQUIRED enumeration facade returns `[]`.

  Rows are maps in the shape the world workspace surfaces render
  (`source`/`uri`/`alive`/`name`/`description`/`members_count`/
  `web_anon_access`/`status`/`body`), live rows first then durable-only
  rows, sorted by `{name, uri}`. `body` carries the RAW template
  content map; the presenter (`WorkspacePluginData`) owns the JSON-safe
  normalization of that field (the world row contract) — this domain
  module does not duplicate the presenter's `jsonable/1` (the arch
  cross-file duplicate-fn gate).

  ## Dependency direction (runtime DI)

  The core enumerations (`KindRegistry`, `KindSnapshot`) and
  `Ezagent.Entity.Session` sit at-or-below this domain. The DI seams
  exist so (a) tests can inject the base listings and (b) the
  `Ezagent.Socialware.DefinitionRegistry` visibility lookup (ABOVE this
  domain) stays cycle-free — its loss fails soft (`web_anon_access:
  false` on the affected rows), never an information leak.
  """

  alias Ezagent.Identity.AdminAuthority
  alias Ezagent.Workspace.WorkspaceReads

  @doc """
  Authorized session-template rows for `caller` in `workspace_name`.

  Fail-closed: `[]` for a nil/malformed/unauthorized caller or an
  unavailable enumeration facade.
  """
  @spec session_templates(URI.t() | term(), String.t() | term()) :: [map()]
  def session_templates(caller, workspace_name)

  def session_templates(%URI{} = caller, workspace_name)
      when is_binary(workspace_name) and workspace_name != "" do
    workspace_uri = Ezagent.URI.workspace(workspace_name)

    with :ok <- authorize_roster(caller, workspace_uri),
         {:ok, live} <- live_rows(workspace_name),
         {:ok, persisted} <- persisted_rows(workspace_name, MapSet.new(live, & &1["uri"])) do
      (live ++ persisted)
      |> Enum.sort_by(fn row -> {row["name"], row["uri"] || ""} end)
    else
      _ -> []
    end
  end

  def session_templates(_caller, _workspace_name), do: []

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

  # ----- live template rows (global registry, workspace-filtered) -----

  defp live_rows(workspace_name) do
    registry = template_registry_facade()
    session = template_session_facade()

    if Code.ensure_loaded?(registry) and function_exported?(registry, :list_all, 0) and
         Code.ensure_loaded?(session) and function_exported?(session, :ensure_template_alive, 1) and
         function_exported?(session, :read_template_content, 1) do
      {:ok,
       registry.list_all()
       |> Enum.flat_map(fn {uri_str, pid} ->
         with {:ok, uri} <- Ezagent.URI.parse(uri_str),
              true <- session_template_for_workspace?(uri, workspace_name),
              {:ok, _pid} <- session.ensure_template_alive(uri),
              {:ok, content} <- session.read_template_content(uri) do
           [
             %{
               "name" => template_family_name(uri, content),
               "source" => "session_template",
               "uri" => uri_str,
               "alive" => is_pid(pid) and Process.alive?(pid),
               "description" => template_description(content),
               "members_count" => template_member_count(content),
               "web_anon_access" => web_anon_access?(content),
               "status" => "session_template",
               "body" => content
             }
           ]
         else
           _ -> []
         end
       end)}
    else
      {:error, {:template_registry_unavailable, registry}}
    end
  end

  # ----- durable template rows (global snapshot scan, workspace-filtered)

  # Durable session templates from snapshots (not currently live in the
  # registry) — the substrate does NOT respawn every template Kind on
  # boot, so the live registry alone drops published templates after a
  # cold restart. Name is parsed from the URI
  # (`template://session/<ws>/<name>@<hash>`); content isn't read (that
  # needs a live Kind), which is fine — the dropdown only needs the
  # name, and creating from it revives the template via the DB-scanning
  # resolver.
  defp persisted_rows(workspace_name, exclude_uris) do
    snapshot = template_snapshot_facade()

    if Code.ensure_loaded?(snapshot) and function_exported?(snapshot, :list_all, 0) do
      {:ok,
       snapshot.list_all()
       |> Enum.flat_map(fn snap ->
         uri_str = Map.get(snap, :uri)

         with "session_template" <- Map.get(snap, :kind_type),
              true <- is_binary(uri_str) and not MapSet.member?(exclude_uris, uri_str),
              {:ok, %URI{} = uri} <- Ezagent.URI.parse(uri_str),
              true <- session_template_for_workspace?(uri, workspace_name) do
           [
             %{
               "name" => template_family_name(uri, %{}),
               "source" => "session_template",
               "uri" => uri_str,
               "alive" => false,
               "description" => "",
               "members_count" => 0,
               "web_anon_access" => false,
               "status" => "session_template",
               "body" => %{}
             }
           ]
         else
           _ -> []
         end
       end)}
    else
      {:error, {:template_snapshot_unavailable, snapshot}}
    end
  end

  # ----- row shaping (moved verbatim from the retired presenter path) --

  defp session_template_for_workspace?(%URI{scheme: "template"} = uri, workspace_name) do
    Ezagent.URI.type?(uri, :session) and
      case Ezagent.URI.workspace_of(uri) do
        %URI{} = ws_uri -> Ezagent.URI.name!(ws_uri) == workspace_name
        _ -> false
      end
  end

  defp session_template_for_workspace?(_, _), do: false

  defp template_family_name(_uri, %{name: name}) when is_binary(name), do: name
  defp template_family_name(_uri, %{"name" => name}) when is_binary(name), do: name

  defp template_family_name(%URI{} = uri, _content) do
    uri
    |> URI.to_string()
    |> String.split("/")
    |> List.last()
    |> to_string()
    |> String.split("@")
    |> List.first()
  end

  defp template_description(%{description: description}) when is_binary(description),
    do: description

  defp template_description(%{"description" => description}) when is_binary(description),
    do: description

  defp template_description(_), do: nil

  defp template_member_count(%{"members" => members}) when is_list(members), do: length(members)
  defp template_member_count(%{members: members}) when is_list(members), do: length(members)
  defp template_member_count(_), do: 0

  defp web_anon_access?(content) when is_map(content) do
    content
    |> installs()
    |> Enum.any?(&socialware_web_anon_access?/1)
  end

  defp web_anon_access?(_), do: false

  defp installs(content) do
    case Map.get(content, :installs) || Map.get(content, "installs") do
      installs when is_list(installs) -> installs
      _ -> []
    end
  end

  # The socialware DefinitionRegistry sits ABOVE this domain — resolved
  # at runtime, fail-soft: unavailable → the row renders
  # `web_anon_access: false` (never a leak, never a crash).
  defp socialware_web_anon_access?(ref) when is_binary(ref) do
    facade = socialware_visibility_facade()

    if Code.ensure_loaded?(facade) and function_exported?(facade, :lookup, 2) do
      case facade.lookup(Ezagent.URI.workspace(:system), ref) do
        {:ok, definition, _object} ->
          definition.visibility_policy.web_anon_access == true

        :error ->
          false
      end
    else
      false
    end
  end

  defp socialware_web_anon_access?(%{"ref" => ref}), do: socialware_web_anon_access?(ref)
  defp socialware_web_anon_access?(%{ref: ref}), do: socialware_web_anon_access?(ref)
  defp socialware_web_anon_access?(_), do: false

  # ----- runtime-DI facades (see moduledoc) ----------------------------

  defp template_registry_facade do
    Application.get_env(
      :ezagent_domain_session,
      :template_registry_facade,
      Ezagent.KindRegistry
    )
  end

  defp template_snapshot_facade do
    Application.get_env(
      :ezagent_domain_session,
      :template_snapshot_facade,
      Ezagent.Ecto.KindSnapshot
    )
  end

  defp template_session_facade do
    Application.get_env(
      :ezagent_domain_session,
      :template_session_facade,
      Ezagent.Entity.Session
    )
  end

  defp socialware_visibility_facade do
    Application.get_env(
      :ezagent_domain_session,
      :socialware_visibility_facade,
      Ezagent.Socialware.DefinitionRegistry
    )
  end
end
