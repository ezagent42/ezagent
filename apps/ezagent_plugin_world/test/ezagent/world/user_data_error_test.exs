defmodule Ezagent.World.UserDataErrorTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.UserData

  test "known permission errors are human-readable" do
    assert UserData.error_message(:unauthorized) == "没有用户管理权限"
  end

  test "unknown reasons never expose raw atoms or tuples" do
    message = UserData.error_message({:some_internal_atom, :boom})
    assert message =~ "联系 workspace founder"
    refute message =~ "some_internal_atom"
    refute message =~ "boom"
  end

  test "profile failures give an actionable retry message" do
    assert UserData.error_message({:profile_failed, :timeout}) == "保存个人资料失败，请稍后重试"
  end
end
