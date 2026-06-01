defmodule EzagentPluginCustomerChat.SoulStore do
  @moduledoc """
  Single source of truth for customer-soul resolution and edited-file I/O.

  Resolution (used by BOTH the editor and the cc spawn path): edited file →
  fixture (immutable seed) → nil. The editor writes ONLY the soul body; the
  channel preamble is prepended by `cc_agent` at spawn (see design §4).

  Layout (role = "customer"):
    <sandbox_root>/<tenant>/souls/<role>.md        edited   (writable override)
    <sandbox_root>/<tenant>/souls/<role>.prev.md   prev     (single-step undo)
    <soul_root>/<tenant>/souls/<role>.md           fixture  (immutable seed)
  """

  @sandbox_default "~/poc-sandbox-phase2"

  @spec effective_path(String.t(), String.t()) :: Path.t() | nil
  def effective_path(tenant, role) do
    ep = edited_path(tenant, role)
    if File.exists?(ep), do: ep, else: fixture_path(tenant, role)
  end

  @spec edited_path(String.t(), String.t()) :: Path.t()
  def edited_path(tenant, role), do: Path.join([sandbox_root(), tenant, "souls", "#{role}.md"])

  @spec prev_path(String.t(), String.t()) :: Path.t()
  def prev_path(tenant, role), do: Path.join([sandbox_root(), tenant, "souls", "#{role}.prev.md"])

  @spec fixture_path(String.t(), String.t()) :: Path.t() | nil
  def fixture_path(tenant, role) do
    path = Path.join([soul_root(), tenant, "souls", "#{role}.md"])
    if File.exists?(path), do: path, else: nil
  end

  @spec read_effective(String.t(), String.t()) :: {:ok, String.t(), :edited | :fixture | :none}
  def read_effective(tenant, role) do
    case effective_path(tenant, role) do
      nil ->
        {:ok, "", :none}

      path ->
        source = if path == edited_path(tenant, role), do: :edited, else: :fixture

        case File.read(path) do
          {:ok, body} -> {:ok, body, source}
          {:error, _} -> {:ok, "", :none}
        end
    end
  end

  @spec write(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write(tenant, role, body) do
    ep = edited_path(tenant, role)
    File.mkdir_p!(Path.dirname(ep))
    if File.exists?(ep), do: File.cp!(ep, prev_path(tenant, role))
    File.write(ep, body)
  end

  @spec revert_previous(String.t(), String.t()) :: :ok | {:error, :no_previous}
  def revert_previous(tenant, role) do
    pp = prev_path(tenant, role)

    if File.exists?(pp) do
      File.cp!(pp, edited_path(tenant, role))
      :ok
    else
      {:error, :no_previous}
    end
  end

  @spec reset(String.t(), String.t()) :: :ok
  def reset(tenant, role) do
    File.rm(edited_path(tenant, role))
    File.rm(prev_path(tenant, role))
    :ok
  end

  @spec edited?(String.t(), String.t()) :: boolean()
  def edited?(tenant, role), do: File.exists?(edited_path(tenant, role))

  @spec has_previous?(String.t(), String.t()) :: boolean()
  def has_previous?(tenant, role), do: File.exists?(prev_path(tenant, role))

  defp sandbox_root do
    Path.expand(
      Application.get_env(
        :ezagent_plugin_customer_chat,
        :customer_chat_sandbox_root,
        @sandbox_default
      )
    )
  end

  defp soul_root do
    # This module sits beside bootstrap.ex at
    # apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex
    # → five `..` from __ENV__.file (file-as-dir) reach the repo root, matching the
    # path bootstrap.ex used before this refactor.
    root_default = Path.expand("../../../../../poc/fixtures/plugins", __ENV__.file)
    Application.get_env(:ezagent_plugin_customer_chat, :customer_chat_soul_root, root_default)
  end
end
