defmodule Ezagent.Template.GenericSession do
  @moduledoc """
  First concrete `Ezagent.Kind.Template` Class — declare a Session by name
  + members, auto-recreate on boot.

  ## Template data shape

      %{
        "class" => "session.generic",            # required, picked up by Workspace.add_template/3
        "session_name" => "architect-review",    # required — becomes session://<name>
        "members" => ["entity://user/system/admin", "entity://agent/team-alpha/cc_architect"],  # URI strings
        "routing_rules" => [...]                 # optional; v1 ignored with warning if present
      }

  ## Why this Class first (per Spec 01 §2.C)

  Proves the contract works using existing Chat primitives only —
  `session://` scheme + `chat/join` action. Zero new concepts. Gives
  every Workspace a useful day-1 capability:
  "declare a Session by name + members, auto-recreate on boot".

  ## Why in chat plugin not ezagent_core

  Per Decision #106 logic — depends on Session Kind + Chat behaviour,
  both owned by chat plugin. Plugin author's natural unit of
  composition.

  ## Idempotency

  Per Spec 01 Q6 — `instantiate/3` MUST be idempotent. This impl
  relies on:
  - `Ezagent.SpawnRegistry.spawn/1` returning `{:ok, existing_pid}` if
    Session is already alive (Phase 4c contract)
  - `chat/join` being safely re-dispatchable (Chat.invoke(:join) is a
    set-membership op; adding a member twice is a no-op)
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "session.generic"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_session_name(tmpl),
         :ok <- check_members(tmpl),
         :ok <- check_unknown_keys(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "session.generic"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_session_name(%{"session_name" => name})
       when is_binary(name) and name != "",
       do: :ok

  defp check_session_name(_), do: {:error, :missing_or_empty_session_name}

  defp check_members(%{"members" => members}) when is_list(members) do
    Enum.reduce_while(members, :ok, fn m, _acc ->
      case parse_uri(m) do
        {:ok, _} -> {:cont, :ok}
        err -> {:halt, {:error, {:invalid_member, m, err}}}
      end
    end)
  end

  defp check_members(%{}), do: :ok
  defp check_members(_), do: {:error, :members_must_be_list}

  @known_keys ~w(class session_name members routing_rules)

  defp check_unknown_keys(tmpl) do
    extra = Map.keys(tmpl) -- @known_keys

    case extra do
      [] -> :ok
      _ -> {:error, {:unknown_keys, extra}}
    end
  end

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"session_name" => session_name} = tmpl, workspace_uri) do
    # SPEC v3 §3.6 (Phase 9 PR-7) — sessions are 3-segment
    # `session://<template>/<workspace>/<name>`. GenericSession is
    # itself the template (template name `generic`).
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    session_uri = Ezagent.URI.session(workspace_name, :generic, session_name)

    with {:ok, _session_pid} <- spawn_session(session_uri),
         :ok <- join_members(session_uri, Map.get(tmpl, "members", [])),
         :ok <- warn_if_routing_rules_present(tmpl) do
      {:ok, [session_uri]}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri),
    do: {:error, {:invalid_template, tmpl}}

  defp spawn_session(session_uri) do
    case Ezagent.SpawnRegistry.spawn(session_uri) do
      {:ok, pid} -> {:ok, pid}
      err -> err
    end
  end

  defp join_members(session_uri, members) do
    target =
      Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    admin = Ezagent.Entity.User.admin_uri()

    {:ok, signed_cap} =
      Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    Enum.each(members, fn member_uri_str ->
      # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
      # with try/rescue so the per-member error path stays intact (skip
      # bad member, warn, continue — Invariant #9 graceful surface).
      case safe_parse_member_uri(member_uri_str) do
        {:ok, member_uri} ->
          _ =
            Ezagent.Invocation.dispatch(%Ezagent.Invocation{
              target: target,
              mode: :cast,
              args: %{member: member_uri},
              ctx: %{
                caller: admin,
                authenticated_principal: admin,
                caps: MapSet.new([signed_cap]),
                reply: :ignore
              },
              origin: :trusted_internal
            })

        _ ->
          Logger.warning(
            "GenericSession: bad member URI #{inspect(member_uri_str)} for session " <>
              "#{URI.to_string(session_uri)}, skipping"
          )
      end
    end)

    :ok
  end

  defp warn_if_routing_rules_present(%{"routing_rules" => rules}) when rules != [] do
    Logger.warning(
      "GenericSession: routing_rules in template are ignored in v1 — wire " <>
        "Workspace.set_routing_rules separately"
    )

    :ok
  end

  defp warn_if_routing_rules_present(_), do: :ok

  defp parse_uri(s) when is_binary(s) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the `{:error, :bad_uri}` shape; returns
    # the scheme of a valid Ezagent URI.
    try do
      %URI{scheme: scheme} = Ezagent.URI.new!(s)
      {:ok, scheme}
    rescue
      ArgumentError -> {:error, :bad_uri}
    end
  end

  defp parse_uri(_), do: {:error, :not_a_string}

  defp safe_parse_member_uri(s) when is_binary(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_parse_member_uri(_), do: :error

  # --- Ezagent.UI.Form ---------------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "session_name",
        type: :text,
        label: "Session name",
        required: true,
        placeholder: "architect-review"
      },
      %{
        name: "members_csv",
        type: :text,
        label: "Members (comma-separated URIs)",
        required: false,
        placeholder: "admin,cc_architect"
      }
    ]
  end

  @impl Ezagent.UI.Form
  def form_to_args(params) do
    members =
      params
      |> Map.get("members_csv", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      "class" => template_name(),
      "session_name" => Map.get(params, "session_name", ""),
      "members" => members
    }
  end
end
