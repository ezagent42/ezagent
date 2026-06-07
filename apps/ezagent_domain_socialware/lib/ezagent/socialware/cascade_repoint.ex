defmodule Ezagent.Socialware.CascadeRepoint do
  @moduledoc """
  #607 — repoint a target agent's #17 high cascade layer at an IMMUTABLE
  socialware config object (spec §7.4: approval "repoints the agent's #17 high
  cascade layer at it" — *it* being the new immutable config object).

  This is the production wiring that makes the self-evolve flow CONSUME the #17
  cascade: after a config-delta writes a new immutable object, the target agent's
  persisted `cascade_resolution.user_layer_uri` is set to that object's stable
  `resource://` URI (`Ezagent.Socialware.ConfigProjection.object_uri/2`). On the
  agent's next spawn, `Ezagent.Credential.CascadeRuntime` re-resolves the layer
  through `:config_dir` → the socialware projection → the materializer, so the
  resolved soul reflects that specific immutable object. Rollback repoints the
  layer at the PRIOR object's URI; because each layer URI names a specific
  immutable object, there is no read/write race and no version-diffing.

  The high layer is the **user** layer (spec's "high cascade layer"; user >
  workspace in the cascade precedence flavor_base → workspace → user → session,
  and the session layer is per-session not per-agent). `:config_dir` is
  read/written through the agent's `Ezagent.Behavior.Sandbox` (`read` +
  `write_path`), the existing seam that owns `respawn_template_data`.

  ## Authorization (#607 codex HIGH)

  The downstream `sandbox.read` + `sandbox.write_path` against the TARGET agent
  are agent-internal effects, NOT actions the calling user can perform directly:
  a normal user's `User.default_caps/1` grant is session-scoped, not
  Sandbox-on-the-target-agent. The `apply_delta`/`repoint` action ITSELF is gated
  by the caller's caps (in `Ezagent.Behavior.ConfigUpdate`); once that passes, the
  sandbox effect runs under the closed-catalog `system://agent-internal`
  principal — the SAME principal `Ezagent.Entity.Agent.record_sandbox_state/3`
  already uses for `sandbox.write_path`. We do NOT widen the user's caps.
  """

  alias Ezagent.Invocation
  alias Ezagent.Socialware.ConfigProjection

  @internal_principal "agent-internal"

  @doc """
  Set `agent_uri`'s user cascade layer to point at the immutable config object
  `object_id` (in `workspace_uri`).

  Returns `:ok` on success, `{:error, reason}` otherwise (fail loud — no silent
  default). `{:error, :no_cascade_resolution}` when the agent has no
  `cascade_resolution` yet: a pre-cascade / non-credentialled agent cannot
  consume the layer, and silently inventing one would diverge from #17's
  create-time resolution. The caller (`Ezagent.Behavior.ConfigUpdate`) surfaces
  this as an error (NOT a silent `:deferred`), because there is no durable place
  to record the pointer for such an agent (#607 codex HIGH).

  The `agent_uri` is the agent whose layer is repointed; the sandbox read/write
  run under `system://agent-internal` (see moduledoc) — the inbound `ctx` is NOT
  used to authorize the sandbox effect.
  """
  @spec repoint_user_layer(URI.t(), URI.t() | String.t(), String.t()) :: :ok | {:error, term()}
  def repoint_user_layer(%URI{} = agent_uri, workspace_uri, object_id)
      when is_binary(object_id) do
    object_uri = ConfigProjection.object_uri(workspace_uri, object_id)

    with {:ok, sandbox} <- read_sandbox(agent_uri),
         {:ok, rtd, resolution} <- fetch_resolution(sandbox),
         updated_resolution <- put_user_layer(resolution, object_uri),
         updated_rtd <- put_resolution(rtd, updated_resolution),
         :ok <- write_sandbox(agent_uri, sandbox, updated_rtd) do
      :ok
    end
  end

  defp read_sandbox(agent_uri) do
    case dispatch(agent_uri, :read, %{}) do
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

  defp put_user_layer(resolution, object_uri) do
    key =
      if Map.has_key?(resolution, :user_layer_uri), do: :user_layer_uri, else: "user_layer_uri"

    Map.put(resolution, key, URI.to_string(object_uri))
  end

  defp put_resolution(rtd, resolution) do
    key =
      if Map.has_key?(rtd, :cascade_resolution),
        do: :cascade_resolution,
        else: "cascade_resolution"

    Map.put(rtd, key, resolution)
  end

  # Preserve config_dir_path + template_class (write_path overwrites all three);
  # only respawn_template_data changes.
  defp write_sandbox(agent_uri, sandbox, updated_rtd) do
    args = %{
      config_dir_path: Map.get(sandbox, :config_dir_path),
      template_class: Map.get(sandbox, :template_class),
      respawn_template_data: updated_rtd
    }

    case dispatch(agent_uri, :write_path, args) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_sandbox_write, other}}
    end
  end

  # The sandbox read/write against the target agent run under the closed-catalog
  # `system://agent-internal` principal (NOT the caller) — see moduledoc.
  defp dispatch(agent_uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=sandbox.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri(@internal_principal),
        caps:
          @internal_principal
          |> Ezagent.SystemPrincipal.uri()
          |> Ezagent.SystemPrincipal.caps(),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
