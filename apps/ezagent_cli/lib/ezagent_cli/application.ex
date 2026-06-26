defmodule EzagentCli.Application do
  @moduledoc """
  EzagentCli Application — owns the `EzagentCli.FacadeRegistry` ETS table.

  No other children; the CLI itself is a one-shot mix task that builds
  its tree on each invocation.
  """

  use Application

  @impl true
  def start(_type, _args) do
    EzagentCli.FacadeRegistry.init_table()
    register_core_facade_ops()
    Supervisor.start_link([], strategy: :one_for_one, name: EzagentCli.Supervisor)
  end

  # CLI facade ops for operations that aren't Behavior actions.
  # Currently:
  # - workspace create — spawns a Workspace Kind (no instance exists
  #   yet to invoke an action on)
  defp register_core_facade_ops do
    EzagentCli.FacadeRegistry.register(:workspace, :create, &workspace_create_facade/1, %{
      args: [name: :string],
      opts: [members: {:list, :uri}],
      about: "Create a new Workspace (persists + spawns the Kind)"
    })

    EzagentCli.FacadeRegistry.register(
      :agent,
      :spawn_manifest,
      &EzagentCli.AgentManifestFacade.spawn_manifest_facade/1,
      %{
        opts: [
          manifest: :string,
          agent: :uri,
          slots: :string
        ],
        about: "Spawn an Agent from an AgentManifest YAML file"
      }
    )

    # Generic per-instance action dispatch. Role/recipe behaviors (e.g.
    # kanban-manager) are loaded per-instance (RF-1) and therefore absent
    # from the static CLI subcommand tree built off BehaviorRegistry. This
    # facade is the sanctioned headless path to drive them: it builds the
    # `<uri>?action=<behavior>.<action>` target and dispatches through the
    # Router with the caller's token identity/caps. Args are JSON (inline
    # `--args-json` or, for large payloads like a markmap, `--args-file`).
    EzagentCli.FacadeRegistry.register(:agent, :invoke, &agent_invoke_facade/1, %{
      opts: [uri: :uri, action: :string, args_json: :string, args_file: :string],
      about:
        "Dispatch <behavior>.<action> to an agent URI (JSON args via --args-json/--args-file)"
    })

    :ok
  end

  defp agent_invoke_facade(parsed) do
    opts = Map.get(parsed, :options, %{})
    uri = opts[:uri]
    action_str = opts[:action]

    args_source =
      cond do
        is_binary(opts[:args_file]) -> File.read(opts[:args_file])
        is_binary(opts[:args_json]) -> {:ok, opts[:args_json]}
        true -> {:ok, "{}"}
      end

    with %URI{} <- uri || {:error, :uri_required},
         action when is_binary(action) <- action_str || {:error, :action_required},
         {:ok, json} <- args_source,
         {:ok, raw} when is_map(raw) <- Jason.decode(json),
         {caller, caps} when not is_nil(caller) <-
           Process.get(:ezagent_cli_caller_override) || {:error, :no_identity} do
      args = Map.new(raw, fn {k, v} -> {String.to_atom(k), v} end)
      target = Ezagent.URI.new!(URI.to_string(uri) <> "?action=#{action}")

      inv = %Ezagent.Invocation{
        target: target,
        mode: :call,
        args: args,
        ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}, deadline_ms: 30_000}
      }

      case Ezagent.Invocation.dispatch(inv) do
        {:ok, result} ->
          {:ok, result}

        :ok ->
          receive do
            {:ezagent_reply, reply} -> {:ok, reply}
          after
            30_000 -> {:ok, :ok}
          end

        other ->
          other
      end
    else
      {:error, _} = err -> err
      other -> {:error, {:invoke_failed, other}}
    end
  end

  defp workspace_create_facade(parsed) do
    name = parsed.args[:name]
    members = parsed.options[:members] || []

    case Ezagent.Workspace.create(name, %{members: members}) do
      {:ok, _pid} ->
        {:ok,
         %{
           name: name,
           uri: name |> Ezagent.URI.workspace() |> URI.to_string(),
           members: length(members)
         }}

      err ->
        err
    end
  end
end
