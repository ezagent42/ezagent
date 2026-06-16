defmodule EzagentPluginContent.DiffEngine do
  @moduledoc "Simple text diff for sandbox vs release comparison."

  def diff(nil, sandbox_text), do: %{added: String.split(sandbox_text || "", "\n"), removed: []}
  def diff(release_text, nil), do: %{added: [], removed: String.split(release_text || "", "\n")}

  def diff(release_text, sandbox_text) when is_binary(release_text) and is_binary(sandbox_text) do
    release_lines = String.split(release_text, "\n")
    sandbox_lines = String.split(sandbox_text, "\n")
    added = sandbox_lines -- release_lines
    removed = release_lines -- sandbox_lines
    unchanged = sandbox_lines -- added
    %{added: added, removed: removed, unchanged: unchanged}
  end
end
