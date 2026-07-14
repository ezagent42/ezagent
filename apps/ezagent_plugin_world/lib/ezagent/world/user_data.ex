defmodule Ezagent.World.UserData do
  @moduledoc """
  User-management state builders for the world identities surface.
  """

  alias Ezagent.World.CapData

  @doc "List provisioned user rows for the users table component."
  @spec list_users(URI.t() | nil) :: [map()]
  def list_users(workspace_uri) do
    system_members =
      case Ezagent.Workspace.Store.get_by_name("system") do
        %{members: members} -> MapSet.new(members, &Ezagent.URI.stable_key/1)
        _ -> MapSet.new()
      end

    users =
      case workspace_uri do
        %URI{scheme: "workspace"} -> Ezagent.Users.list_in_workspace(workspace_uri)
        _ -> Ezagent.Users.list_all()
      end

    display_map = Ezagent.EntityPresenter.display_many(Enum.map(users, &URI.to_string(&1.uri)))

    users
    |> Enum.map(fn user ->
      uri_str = URI.to_string(user.uri)
      online? = Ezagent.Presence.present?(user.uri)
      profile = Ezagent.Entity.Profile.get(user.uri)
      cap_count = length(user.caps)

      %{
        "uri" => uri_str,
        "display_name" => Map.get(display_map, uri_str, uri_str),
        "email" => profile_email(profile),
        "has_password" => not is_nil(user.password_hash),
        "confirmed" => user.confirmed == true,
        "email_verified" => user.email_verified == true,
        "disabled" => not is_nil(user.disabled_at),
        "disabled_at" => encode_datetime(user.disabled_at),
        "disabled_by" => user.disabled_by,
        "disabled_reason" => user.disabled_reason,
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

  @doc "Build the user detail payload."
  @spec detail_state(map(), URI.t(), URI.t() | nil, MapSet.t()) :: map()
  def detail_state(base, user_uri, caller, caps) do
    user = Ezagent.Users.get_by_uri(user_uri)
    profile = Ezagent.Entity.Profile.get(user_uri)
    user_uri_str = URI.to_string(user_uri)
    cap_count = length(user.caps)

    base
    |> Map.put("user_uri", user_uri_str)
    |> Map.put(
      "display_name",
      profile_display_name(profile) || user_name(user_uri) || user_uri_str
    )
    |> Map.put("email", profile_email(profile))
    |> Map.put("has_password", not is_nil(user.password_hash))
    |> Map.put("confirmed", user.confirmed == true)
    |> Map.put("email_verified", user.email_verified == true)
    |> Map.put("disabled", not is_nil(user.disabled_at))
    |> Map.put("disabled_at", encode_datetime(user.disabled_at))
    |> Map.put("disabled_by", user.disabled_by)
    |> Map.put("disabled_reason", user.disabled_reason)
    |> Map.put("cap_count", cap_count)
    |> Map.put("caps_path", caps_path(user_uri_str))
    |> Map.put("granted_caps", CapData.list_entity_caps(user_uri, caller, caps))
    |> Map.put("action_error", nil)
  end

  @doc "Return true when the user row exists."
  @spec exists?(URI.t() | term()) :: boolean()
  def exists?(%URI{} = user_uri), do: not is_nil(Ezagent.Users.get_by_uri(user_uri))
  def exists?(_), do: false

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
