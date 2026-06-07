defmodule Ezagent.Socialware.CascadeRepoint do
  @moduledoc """
  #607 — repoint a target agent's #17 high cascade layer at a socialware config
  pointer (spec §7.4: approval "repoints the agent's #17 high cascade layer").

  This is the production wiring that makes the self-evolve flow CONSUME the #17
  cascade: after a config-delta writes/repoints the immutable object, the target
  agent's persisted `cascade_resolution.user_layer_uri` is set to the pointer's
  stable `resource://` URI (`Ezagent.Socialware.ConfigProjection.pointer_uri/4`).
  On the agent's next spawn, `Ezagent.Credential.CascadeRuntime` re-resolves the
  layer through `:config_dir` → the socialware projection → the materializer, so
  the resolved soul reflects the current object; rollback (repoint to the prior
  object) reverts it deterministically because the layer URI keys the POINTER, so
  it is unchanged across object swaps.

  The high layer is the **user** layer (spec's "high cascade layer"; user > workspace
  in the cascade precedence flavor_base → workspace → user → session, and the
  session layer is per-session not per-agent). `:config_dir` is read/written
  through the agent's `Ezagent.Behavior.Sandbox` (`read` + `write_path`), the
  existing seam that owns `respawn_template_data`.
  """

  alias Ezagent.Invocation
  alias Ezagent.Socialware.ConfigProjection

  @doc """
  Set `agent_uri`'s user cascade layer to point at the `key`'s socialware config
  pointer. `ctx` is the invoking behavior context (supplies caller + caps).

  Returns `:ok` on success, `{:error, reason}` otherwise (fail loud — no silent
  default). `{:error, :no_cascade_resolution}` when the agent has no
  `cascade_resolution` yet: a pre-cascade / non-credentialled agent cannot
  consume the layer, and silently inventing one would diverge from #17's
  create-time resolution. The caller (`Ezagent.Behavior.ConfigUpdate`) surfaces
  this as an error (NOT a silent `:deferred`), because there is no durable place
  to record the pointer for such an agent (#607 codex HIGH).
  """
  @spec repoint_user_layer(URI.t(), atom() | String.t(), URI.t(), URI.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def repoint_user_layer(%URI{} = agent_uri, config_layer, workspace_uri, subject_uri, key, ctx)
      when is_map(ctx) do
    pointer_uri = ConfigProjection.pointer_uri(config_layer, workspace_uri, subject_uri, key)

    with {:ok, sandbox} <- read_sandbox(agent_uri, ctx),
         {:ok, rtd, resolution} <- fetch_resolution(sandbox),
         updated_resolution <- put_user_layer(resolution, pointer_uri),
         updated_rtd <- put_resolution(rtd, updated_resolution),
         :ok <- write_sandbox(agent_uri, sandbox, updated_rtd, ctx) do
      :ok
    end
  end

  defp read_sandbox(agent_uri, ctx) do
    case dispatch(agent_uri, :read, %{}, ctx) do
      {:ok, sandbox} when is_map(sandbox) -> {:ok, sandbox}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_sandbox_read, other}}
    end
  end

  defp fetch_resolution(sandbox) do
    rtd = Map.get(sandbox, :respawn_template_data)

    resolution =
      case rtd do
        %{} = data -> data["cascade_resolution"] || data[:cascade_resolution]
        _ -> nil
      end

    case resolution do
      %{} = res -> {:ok, rtd, res}
      _ -> {:error, :no_cascade_resolution}
    end
  end

  defp put_user_layer(resolution, pointer_uri) do
    key =
      if Map.has_key?(resolution, :user_layer_uri), do: :user_layer_uri, else: "user_layer_uri"

    Map.put(resolution, key, URI.to_string(pointer_uri))
  end

  # NOTE: `URI.to_string/1` and `URI.new!/1` below use Elixir's stdlib `URI`
  # for `to_string` and `Ezagent.URI.new!` is referenced fully-qualified.

  defp put_resolution(rtd, resolution) do
    key =
      if Map.has_key?(rtd, :cascade_resolution),
        do: :cascade_resolution,
        else: "cascade_resolution"

    Map.put(rtd, key, resolution)
  end

  # Preserve config_dir_path + template_class (write_path overwrites all three);
  # only respawn_template_data changes.
  defp write_sandbox(agent_uri, sandbox, updated_rtd, ctx) do
    args = %{
      config_dir_path: Map.get(sandbox, :config_dir_path),
      template_class: Map.get(sandbox, :template_class),
      respawn_template_data: updated_rtd
    }

    case dispatch(agent_uri, :write_path, args, ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_sandbox_write, other}}
    end
  end

  defp dispatch(agent_uri, action, args, ctx) do
    target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=sandbox.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: Map.fetch!(ctx, :caller),
        caps: Map.get(ctx, :caps, MapSet.new()),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
