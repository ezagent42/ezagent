defmodule Ezagent.Workspace do
  @moduledoc """
  Workspace facade — spawn + query + durable mutation helpers.

  Phase 4b: `spawn_workspace/2` for in-memory Workspace Kinds.
  Phase 4c: `create/2` (persist + spawn), `add_member/2` etc. (persist
  + dispatch), `Loader` at app start.

  ## Durable mutation contract

  Mutation helpers (`add_member`, `remove_member`, `add_template`,
  `remove_template`, `set_routing_rules`) perform two writes:
  1. `Ezagent.Workspace.Store.update_*` — durable
  2. `Invocation.dispatch(:<action>, ...)` — live Kind

  Both succeed atomically per call (no transaction across them yet —
  Phase 5 may wrap in a single transactional path). The DB write is
  first so a crash between (1) and (2) at most leaves a Workspace in
  DB that doesn't match the live Kind for one boot — Loader resyncs on
  next start.

  Read paths (`list_members`, `list_templates`, etc.) go through the
  live Kind only; the DB is the recovery snapshot, not the read source.
  """

  alias Ezagent.Entity.Workspace, as: WK
  alias Ezagent.{Invocation, KindRegistry, Workspace.Loader, Workspace.Store}

  # --- spawn ---------------------------------------------------------

  @doc """
  Spawn a Workspace Kind at `workspace://<name>` with the given
  initial slice args. In-memory only — use `create/2` for durable.
  """
  @spec spawn_workspace(String.t(), map()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_workspace(name, args \\ %{}) when is_binary(name) do
    uri = WK.uri_for(name)

    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        {:error, {:already_started, pid}}

      :error ->
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        # Workspace Kind declares `Ezagent.Workspace.Supervisor` via its
        # supervisor/0 callback so the destination is preserved.
        Ezagent.Kind.spawn(WK, Map.put(args, :uri, uri))
    end
  end

  # --- durable create -----------------------------------------------

  @doc """
  Persist a new Workspace + spawn its Kind. Use this from mix tasks /
  LV — `spawn_workspace/2` alone gives an ephemeral Workspace that
  vanishes on restart.

  `attrs` shape matches `Ezagent.Workspace.Store.create/2`.
  """
  @spec create(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def create(name, attrs \\ %{}) when is_binary(name) and name != "" do
    with {:ok, _decoded} <- Store.create(name, attrs),
         {:ok, pid} <- spawn_workspace(name, attrs) do
      {:ok, pid}
    end
  end

  # --- durable mutations --------------------------------------------

  @doc """
  Add `member_uri` to Workspace `name`. Writes to DB then dispatches
  `:add_member` on the live Workspace Kind so subsequent `list_members`
  returns the new member.
  """
  @spec add_member(String.t(), URI.t()) :: :ok | {:error, term()}
  def add_member(name, %URI{} = member_uri) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      %{members: existing} ->
        new_members = Enum.uniq([member_uri | existing])

        with {:ok, _} <- Store.update_members(name, new_members),
             :ok <- dispatch_mutation(name, "add_member", %{member: member_uri}) do
          # Notifier/flash audit 2026-05-24 — surface to the affected
          # user's notification stream. Pre-fix only `Chat.receive`
          # called notify/3; cap/membership actions were silent.
          # Skip for agent members (Notifications is user-only by
          # design — agents don't have inboxes).
          if user_uri?(member_uri) do
            _ =
              Ezagent.Notifications.notify(member_uri, %{
                type: :workspace_member_added,
                body: %{
                  text: "You were added to workspace #{name}.",
                  workspace_name: name
                },
                source: __MODULE__
              })
          end

          :ok
        end
    end
  end

  @spec remove_member(String.t(), URI.t()) :: :ok | {:error, term()}
  def remove_member(name, %URI{} = member_uri) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      %{members: existing} ->
        new_members = Enum.reject(existing, &(URI.to_string(&1) == URI.to_string(member_uri)))

        with {:ok, _} <- Store.update_members(name, new_members),
             :ok <- dispatch_mutation(name, "remove_member", %{member: member_uri}) do
          # Skip for agent members (Notifications is user-only by design —
          # agents don't have inboxes); mirrors the `add_member` guard.
          if user_uri?(member_uri) do
            _ =
              Ezagent.Notifications.notify(member_uri, %{
                type: :workspace_member_removed,
                body: %{
                  text: "You were removed from workspace #{name}.",
                  workspace_name: name
                },
                source: __MODULE__
              })
          end

          :ok
        end
    end
  end

  @doc """
  Add a template to a Workspace. Fail-fast structural validation:
  - template map must carry a `"class"` field referencing a registered
    `Ezagent.Kind.Template` Class
  - Class's `validate/1` (if defined) is called before persistence

  Per Phase 4-completion Spec 01 Q2-(b): `"class"` field is the source
  of truth for template Class binding. Multiple instances per Class are
  fine — they're distinguished by the Workspace-local `tmpl_name` key.

  ## V1 acceptance fix (2026-05-21)

  The full chain is now:
  1. DB JSON updated (`Store.update_templates`)
  2. Live Workspace Kind notified (`dispatch_mutation`)
  3. **Template Class instantiated** (`Loader.invoke_template`) — runs
     `Class.instantiate/3`, brings the spawned Kinds (PtyServer for
     cc.agent, Session for session.generic, etc.) to life immediately
     so any caller (`AgentNewLive`, CLI, future API) gets a running
     agent without needing a phx restart.

  An instantiate `{:error, {:already_started, _}}` is treated as
  success (idempotent w.r.t. step 3 — re-running on an already-alive
  Kind is a no-op). Any other instantiate error is returned to the
  caller (per `feedback_let_it_crash_no_workarounds` — no silent
  swallow).
  """
  @spec add_template(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def add_template(name, tmpl_name, tmpl) when is_binary(tmpl_name) and is_map(tmpl) do
    with :ok <- validate_template(tmpl),
         %{session_templates: tmpls} <- get_or_not_found(name),
         new_tmpls = Map.put(tmpls, tmpl_name, tmpl),
         {:ok, _} <- Store.update_templates(name, new_tmpls),
         :ok <-
           dispatch_mutation(name, "add_template", %{name: tmpl_name, template: tmpl}),
         :ok <- invoke_template_now(name, tmpl_name) do
      :ok
    end
  end

  defp invoke_template_now(name, tmpl_name) do
    workspace_uri = URI.parse("workspace://#{name}")

    case Loader.invoke_template(workspace_uri, tmpl_name) do
      {:ok, _uris} -> :ok
      # Idempotent — already running. cc.agent.instantiate already
      # short-circuits, but defensive in case other templates return
      # this shape.
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp get_or_not_found(name) do
    case Store.get_by_name(name) do
      nil -> {:error, :not_found}
      decoded -> decoded
    end
  end

  defp validate_template(tmpl) do
    case extract_class_name(tmpl) do
      nil ->
        {:error, :missing_class_field}

      class_name ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          :error ->
            {:error, {:no_template_class, class_name}}

          {:ok, class_module} ->
            invoke_validate(class_module, tmpl)
        end
    end
  end

  defp invoke_validate(class_module, tmpl) do
    if function_exported?(class_module, :validate, 1) do
      class_module.validate(tmpl)
    else
      :ok
    end
  end

  defp extract_class_name(%{"class" => name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(%{class: name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(_), do: nil

  @spec remove_template(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_template(name, tmpl_name) when is_binary(tmpl_name) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      %{session_templates: tmpls} ->
        new_tmpls = Map.delete(tmpls, tmpl_name)

        with {:ok, _} <- Store.update_templates(name, new_tmpls),
             :ok <- dispatch_mutation(name, "remove_template", %{name: tmpl_name}) do
          :ok
        end
    end
  end

  @spec set_routing_rules(String.t(), [map()]) :: :ok | {:error, term()}
  def set_routing_rules(name, rules) when is_list(rules) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      _ ->
        with {:ok, _} <- Store.update_routing_rules(name, rules),
             :ok <- dispatch_mutation(name, "set_routing_rules", %{rules: rules}) do
          :ok
        end
    end
  end

  defp dispatch_mutation(name, action_str, args) do
    target = URI.parse("workspace://#{name}?action=workspace.#{action_str}")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :cast,
           args: args,
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: :ignore
           }
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      err -> err
    end
  end

  # --- listing -------------------------------------------------------

  @doc """
  List all live Workspace URIs (those registered in KindRegistry under
  the `workspace://` scheme).
  """
  @spec list_workspaces() :: [URI.t()]
  def list_workspaces do
    KindRegistry.list_all()
    |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "workspace://") end)
    |> Enum.map(fn {uri_str, _pid} -> URI.parse(uri_str) end)
    |> Enum.sort_by(&URI.to_string/1)
  end

  @doc "List persisted Workspaces (decoded structs from `Ezagent.Workspace.Store`)."
  @spec list_persisted() :: [map()]
  def list_persisted, do: Store.list_all()

  @doc """
  List all persisted workspaces — admin / loader / mix-task use.
  Returns hidden workspaces (e.g. `workspace://system`) too.

  Phase 9 PR-8 (SPEC v3 §13.1): callers rendering operator-facing UI
  should use `list_visible/0` instead so the system workspace stays
  hidden from regular users.
  """
  @spec list_all() :: [map()]
  def list_all, do: Store.list_all()

  @doc """
  List only workspaces with `visible: true` — the operator-facing
  surface (workspace dropdown, /workspaces page for non-admins).

  Phase 9 PR-8 (SPEC v3 §13.1). `workspace://system` is created with
  `visible: false` at boot and MUST NOT appear in the regular
  selector.
  """
  @spec list_visible() :: [map()]
  def list_visible, do: Store.list_visible()

  # --- magic-link rules (SPEC 2026-05-24 v2 PR-A) ----------------------

  alias Ezagent.Workspace.MagicLinkRule

  @doc """
  Does any workspace's magic-link rule accept `email`?

  This is the SEND-side gate (OQ-V2-3): when an operator clicks
  "send magic link" for an email, we OR across all workspaces and
  reject if no rule matches. Pre-PR-A this was a flat global
  `registration_domains` AppSetting; now it's per-workspace rules.
  """
  @spec any_workspace_accepts?(String.t()) :: boolean()
  def any_workspace_accepts?(email) when is_binary(email) do
    MagicLinkRule.workspaces_accepting(email) != []
  end

  def any_workspace_accepts?(_), do: false

  @doc """
  Does a specific workspace accept `email`? Used by the CLICK-side
  gate (OQ-V2-3) after the token is verified, AND by the onboarding
  LV (PR-B) when the user tries to join workspace X by name.
  """
  @spec accepts_email?(URI.t() | String.t(), String.t()) :: boolean()
  def accepts_email?(workspace_uri, email),
    do: MagicLinkRule.accepts_email?(workspace_uri, email)

  @doc """
  List workspaces that would accept `email` — for the onboarding LV
  (PR-B) to suggest "you can join any of these existing workspaces."
  Returns workspace URIs as strings.
  """
  @spec workspaces_accepting(String.t()) :: [String.t()]
  def workspaces_accepting(email), do: MagicLinkRule.workspaces_accepting(email)

  @doc "Add a magic-link rule to a workspace. See `MagicLinkRule.add/3`."
  defdelegate add_magic_link_rule(workspace_uri, rule_type, rule_value),
    to: MagicLinkRule,
    as: :add

  @doc "List magic-link rules for a workspace. See `MagicLinkRule.list_for/1`."
  defdelegate list_magic_link_rules(workspace_uri), to: MagicLinkRule, as: :list_for

  @doc "Delete a magic-link rule by id. See `MagicLinkRule.delete/1`."
  defdelegate delete_magic_link_rule(id), to: MagicLinkRule, as: :delete

  # Notifier/flash audit 2026-05-24 — `Ezagent.Notifications.notify/3`
  # only accepts `entity://user/...` URIs (agents don't have inboxes
  # by design). Use this guard at notify call sites where a member
  # URI may be either user or agent.
  defp user_uri?(%URI{scheme: "entity", host: "user"}), do: true
  defp user_uri?(_), do: false
end
