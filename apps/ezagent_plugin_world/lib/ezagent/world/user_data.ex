defmodule Ezagent.World.UserData do
  @moduledoc """
  User-management state builders for the world identities surface.
  """

  alias Ezagent.World.CapData
  alias Ezagent.Workspace.UserReads

  @doc """
  List provisioned user rows for the users table component.

  Read-plane PR-4 rework: the user roster is enumerated through the
  caller-authorizing `Ezagent.Workspace.UserReads` chokepoint (workspace
  member/operator only; fail-closed `[]`), and another user's
  ACCOUNT/SECURITY metadata (email, password presence, confirmation,
  disablement) is emitted ONLY when `UserReads.reveal_metadata?/2`
  holds for that row (the caller IS that user, or is an operator) — F4.
  A redacted field renders `nil` (undisclosed), never `false` (which
  would assert the negation — itself a leak).
  """
  @spec list_users(URI.t() | nil, URI.t() | nil) :: [map()]
  def list_users(caller, workspace_uri) do
    system_members =
      case Ezagent.Workspace.Store.get_by_name("system") do
        %{members: members} -> MapSet.new(members, &Ezagent.URI.stable_key/1)
        _ -> MapSet.new()
      end

    users = UserReads.users(caller, workspace_uri)

    display_map = Ezagent.EntityPresenter.display_many(Enum.map(users, &URI.to_string(&1.uri)))

    users
    |> Enum.map(fn user ->
      uri_str = URI.to_string(user.uri)
      online? = Ezagent.Presence.present?(user.uri)
      reveal? = UserReads.reveal_metadata?(caller, user.uri)
      profile = if reveal?, do: Ezagent.Entity.Profile.get(user.uri), else: nil
      cap_count = verified_cap_count(user.uri)

      %{
        "uri" => uri_str,
        "display_name" => Map.get(display_map, uri_str, uri_str),
        "email" => if(reveal?, do: profile_email(profile)),
        "has_password" => if(reveal?, do: not is_nil(user.password_hash)),
        "confirmed" => if(reveal?, do: user.confirmed == true),
        "email_verified" => if(reveal?, do: user.email_verified == true),
        "disabled" => if(reveal?, do: not is_nil(user.disabled_at)),
        "disabled_at" => if(reveal?, do: encode_datetime(user.disabled_at)),
        "disabled_by" => if(reveal?, do: user.disabled_by),
        "disabled_reason" => if(reveal?, do: user.disabled_reason),
        "cap_count" => cap_count,
        "online" => online?,
        "transports" => transports_summary(Ezagent.Presence.list(user.uri)),
        "system_member" => MapSet.member?(system_members, Ezagent.URI.stable_key(user.uri)),
        "caps_path" => caps_path(uri_str),
        "detail_path" => detail_path(uri_str)
      }
    end)
    |> Enum.sort_by(& &1["uri"])
  rescue
    _ -> []
  end

  @doc """
  Build the user detail payload — the per-URI deep-link reader.

  Read-plane PR-4 re-review: the read routes through the caller-aware
  `Ezagent.Workspace.UserReads.user/2` chokepoint (authorize BEFORE
  existence is checked — no cross-tenant existence oracle). A denied
  caller gets a `user_unauthorized` shell with NO account data; a
  missing user gets `user_not_found`. On an authorized row the
  ACCOUNT/SECURITY metadata (email, password presence, confirmation,
  disablement) is emitted ONLY when `UserReads.reveal_metadata?/2`
  holds (the caller IS that user, or an operator) — redacted fields
  render `nil` (undisclosed), never `false`, and the payload carries
  `can_view_metadata` so the surface hides the sensitive rows and the
  management forms instead of asserting negations.
  """
  @spec detail_state(map(), URI.t(), URI.t() | nil, MapSet.t()) :: map()
  def detail_state(base, user_uri, caller, caps) do
    case UserReads.user(caller, user_uri) do
      {:ok, user} ->
        detail_state_for(base, user_uri, user, caller, caps)

      {:error, :not_found} ->
        base
        |> Map.put("user_uri", URI.to_string(user_uri))
        |> Map.put("user_not_found", true)

      {:error, _unauthorized} ->
        base
        |> Map.put("user_uri", URI.to_string(user_uri))
        |> Map.put("user_unauthorized", true)
    end
  end

  defp detail_state_for(base, user_uri, user, caller, caps) do
    reveal? = UserReads.reveal_metadata?(caller, user_uri)
    profile = if reveal?, do: Ezagent.Entity.Profile.get(user_uri), else: nil
    user_uri_str = URI.to_string(user_uri)
    cap_count = verified_cap_count(user_uri)

    base
    |> Map.put("user_uri", user_uri_str)
    |> Map.put("can_view_metadata", reveal?)
    |> Map.put(
      "display_name",
      profile_display_name(profile) || user_name(user_uri) || user_uri_str
    )
    |> Map.put("email", if(reveal?, do: profile_email(profile)))
    |> Map.put("has_password", if(reveal?, do: not is_nil(user.password_hash)))
    |> Map.put("confirmed", if(reveal?, do: user.confirmed == true))
    |> Map.put("email_verified", if(reveal?, do: user.email_verified == true))
    |> Map.put("disabled", if(reveal?, do: not is_nil(user.disabled_at)))
    |> Map.put("disabled_at", if(reveal?, do: encode_datetime(user.disabled_at)))
    |> Map.put("disabled_by", if(reveal?, do: user.disabled_by))
    |> Map.put("disabled_reason", if(reveal?, do: user.disabled_reason))
    |> Map.put("cap_count", cap_count)
    |> Map.put("caps_path", caps_path(user_uri_str))
    |> Map.put("granted_caps", CapData.list_entity_caps(user_uri, caller, caps))
    |> Map.put("action_error", nil)
  end

  @doc "Preview a user URI under the current workspace."
  @spec preview_uri(URI.t() | nil, String.t()) :: String.t()
  def preview_uri(%URI{scheme: "workspace"} = workspace_uri, name) do
    with trimmed when trimmed != "" <- String.trim(to_string(name)),
         {:ok, workspace_name} <- Ezagent.URI.name(workspace_uri) do
      workspace_name |> Ezagent.URI.user(trimmed) |> URI.to_string()
    else
      _ -> "<user-uri>"
    end
  rescue
    _ -> "<user-uri>"
  end

  def preview_uri(_workspace_uri, _name), do: "<user-uri>"

  @doc "Map a create/update user failure reason to an operator-facing message."
  @spec error_message(term()) :: String.t()
  def error_message(:name_required), do: "请填写 name"
  def error_message(:password_required), do: "请填写 password"
  def error_message(:invalid_workspace_scope), do: "无效的 workspace"
  def error_message(:invalid_user_uri), do: "无效的 user URI"
  def error_message(:user_not_found), do: "User 不存在"
  def error_message(:unauthorized), do: "没有用户管理权限"
  def error_message(:self_disable_denied), do: "不能禁用当前登录用户"
  def error_message({:already_exists, uri}), do: "同名 user 已存在：#{uri}"

  def error_message(%Ecto.Changeset{} = changeset),
    do: "保存失败：#{inspect(changeset.errors)}"

  def error_message({:bad_name, name}),
    do: "name 不合法（字母数字开头，仅 字母/数字/-/_）：#{name}"

  def error_message({:profile_failed, reason}), do: "保存 profile 失败：#{inspect(reason)}"
  def error_message({:bad_workspace_uri, _}), do: "无效的 workspace"
  def error_message({:error, reason}), do: error_message(reason)
  def error_message(other), do: "操作失败：#{inspect(other)}"

  defp profile_display_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp profile_display_name(_), do: nil

  defp profile_email(%{email: email}) when is_binary(email) and email != "", do: email
  defp profile_email(_), do: nil

  defp user_name(%URI{} = user_uri) do
    case Ezagent.URI.name(user_uri) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  defp user_name(_), do: nil

  defp verified_cap_count(%URI{} = user_uri) do
    user_uri
    |> Ezagent.EntityCaps.load()
    |> length()
  rescue
    _ -> 0
  end

  defp caps_path(uri_str), do: "/identities/users/#{URI.encode_www_form(uri_str)}/caps"
  defp detail_path(uri_str), do: "/identities/users/#{URI.encode_www_form(uri_str)}"

  defp transports_summary(presence_list) do
    for entries <- Map.values(presence_list),
        meta <- entries,
        transport = Map.get(meta, :transport),
        not is_nil(transport),
        uniq: true do
      to_string(transport)
    end
  rescue
    _ -> []
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_), do: nil
end
