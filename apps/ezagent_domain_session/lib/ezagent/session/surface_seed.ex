defmodule Ezagent.Session.SurfaceSeed do
  @moduledoc """
  Seed a freshly-created session's `Behavior.Surface` from a page captured into
  its `SessionTemplate` (`content.seed_surface`), so a session instantiated from a
  "published" template renders the SAME page as the session it was published from
  — WITHOUT copying the source session's conversation history.

  This is **generic + core-only**: it mirrors the dispatch sequence
  `EzagentPluginHello.TurnDriver` uses (`turn.open → turn.compose → turn.settle`
  then `surface.set_shell`), but carries NO plugin dependency — it talks only to
  the core `Behavior.Turn` / `Behavior.Surface` actions. So `SessionCreator` can
  seed any surface-bearing template's page without knowing about hello.

  `seed_surface` shape (built by `Orchestrator.Tools.Templates.save_template_as`):

      %{tree: <json-render page spec>, shell: <html frame | "">, shell_css: <css | "">}

  **Best-effort**: a seed failure is logged and swallowed (returns `:ok`) — an
  unseeded session is still a valid session; it must never fail session creation.
  """

  require Logger

  alias Ezagent.Invocation
  alias Ezagent.Entity.User

  @doc """
  Seed `session_uri`'s Surface from `seed_surface` under `actor` authority
  (defaults to the admin genesis authority the Turn recovery path uses). No-op +
  `:ok` when `seed_surface` is absent/malformed or has no page tree.
  """
  @spec seed(URI.t(), term(), URI.t() | nil) :: :ok
  def seed(session_uri, seed_surface, actor \\ nil)

  def seed(%URI{} = session_uri, seed_surface, actor) when is_map(seed_surface) do
    tree = get(seed_surface, :tree)
    shell = get(seed_surface, :shell)
    css = get(seed_surface, :shell_css)
    caller = actor || User.admin_uri()

    if is_map(tree) and map_size(tree) > 0 do
      case drive(session_uri, tree, caller) do
        {:ok, _turn_id} ->
          if (is_binary(shell) and shell != "") or (is_binary(css) and css != "") do
            _ = set_shell(session_uri, caller, shell || "", css || "")
          end

          :ok

        {:error, reason} ->
          Logger.warning(
            "SurfaceSeed: page seed failed on #{URI.to_string(session_uri)}: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("SurfaceSeed: crashed seeding #{URI.to_string(session_uri)}: #{inspect(e)}")

      :ok
  end

  def seed(_session_uri, _seed_surface, _actor), do: :ok

  # turn.open → turn.compose([page]) → turn.settle — lands `spec` as an approved +
  # committed Surface version (mirrors EzagentPluginHello.TurnDriver.drive/4).
  defp drive(session_uri, spec, caller) do
    with {:ok, %{turn_id: turn_id}} <-
           dispatch(
             session_uri,
             :turn,
             :open,
             %{trigger: %{source: "template-seed"}, opened_at: System.system_time(:millisecond)},
             caller
           ),
         {:ok, _composed} <-
           dispatch(
             session_uri,
             :turn,
             :compose,
             %{turn_id: turn_id, result_refs: [%{kind: :page, tree: spec}]},
             caller
           ),
         {:ok, %{status: :settled}} <-
           dispatch(session_uri, :turn, :settle, %{turn_id: turn_id}, caller) do
      {:ok, turn_id}
    else
      {:error, _} = err -> err
      other -> {:error, {:unexpected, other}}
    end
  end

  defp set_shell(session_uri, caller, html, css) do
    dispatch(session_uri, :surface, :set_shell, %{html: html, css: to_string(css)}, caller)
  end

  defp dispatch(session_uri, behavior, action, args, caller) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
    admin = Ezagent.Entity.User.admin_uri()

    with {:ok, signed_cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, caller, target) do
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: args,
        ctx: %{
          caller: caller,
          authenticated_principal: caller,
          caps: MapSet.new([signed_cap]),
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })
    end
  end

  # seed_surface may round-trip with atom OR string keys depending on storage;
  # accept both.
  defp get(m, key) when is_atom(key), do: Map.get(m, key) || Map.get(m, Atom.to_string(key))
end
