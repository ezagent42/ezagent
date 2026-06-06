defmodule Mix.Tasks.Ezagent.Skill.Bootstrap do
  @shortdoc "Bootstrap a new bot from skeleton template (cold-start)"
  @moduledoc """
  Creates a new bot by forking the skeleton template into a workspace.

  ## Usage

      mix ezagent.skill.bootstrap <workspace> <bot_name> <description>

  Example:

      mix ezagent.skill.bootstrap cinnox my-ecommerce \\
        "电商客服, 售前(商品/价格/库存)+售后(退换货/物流), 转人工"

  Flow:
    1. Fork skeleton AgentTemplate from system workspace
    2. Write initial soul_slot_values (empty defaults)
    3. AgentTemplate is ready for admin to fill slot values via LV
       or Authoring Agent

  Idempotent: re-running with the same bot_name converges.
  """

  use Mix.Task

  alias EzagentPluginAutoservice.CinnoxAssets

  @shortdoc @shortdoc

  @impl Mix.Task
  def run([workspace_name, bot_name, description]) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_instance_message)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_autoservice)

    template_name = "autoservice.#{bot_name}"
    workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
    system_template_uri =
      Ezagent.URI.new!("template://agent/system/skeleton")

    Mix.shell().info(
      "Bootstrapping bot `#{bot_name}` in workspace `#{workspace_name}`..."
    )
    Mix.shell().info("  Description: #{description}")

    # 1. Ensure skeleton template exists in system workspace
    :ok = ensure_skeleton_template(system_template_uri)

    # 2. Fork skeleton → workspace
    case fork_template(system_template_uri, template_name, workspace_name) do
      {:ok, tenant_uri} ->
        Mix.shell().info("  Created: #{URI.to_string(tenant_uri)}")
        Mix.shell().info("")
        Mix.shell().info("Next steps:")
        Mix.shell().info("  1. Open LV admin → edit slot values")
        Mix.shell().info("  2. Or: chat with Authoring Agent to customize")
        Mix.shell().info("  3. Spawn agent to test")

      {:error, reason} ->
        Mix.shell().error("  Failed: #{inspect(reason)}")
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix ezagent.skill.bootstrap <workspace> <bot_name> <description>")
  end

  # --- helpers ---

  defp ensure_skeleton_template(system_uri) do
    case Ezagent.KindRegistry.lookup(system_uri) do
      {:ok, _pid} ->
        Mix.shell().info("  Skeleton template already exists")
        :ok

      :error ->
        case Ezagent.SpawnRegistry.spawn(system_uri) do
          {:ok, _pid} ->
            # Write initial skeleton content
            soul_template = File.read!(CinnoxAssets.skeleton_soul_path())
            slot_values = CinnoxAssets.skeleton_default_slot_values()

            ctx = system_task_ctx()
            invoke_template_write(system_uri, soul_template, slot_values, ctx)
            Mix.shell().info("  Skeleton template created")
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            {:error, {:skeleton_spawn_failed, reason}}
        end
    end
  end

  defp fork_template(parent_uri, new_name, workspace_name) do
    # Read parent content
    {:ok, content} = read_template_content(parent_uri)

    # Build fork content
    fork_content = Map.put(content, :name, new_name)

    # Spawn new AgentTemplate in target workspace
    new_uri =
      Ezagent.URI.new!("template://agent/#{workspace_name}/#{new_name}")

    case Ezagent.SpawnRegistry.spawn(new_uri) do
      {:ok, _pid} ->
        # Write forked content + grant caps
        ctx = system_task_ctx()
        invoke_template_write(new_uri, Map.get(fork_content, :soul_template_body), Map.get(fork_content, :soul_slot_values, %{}), ctx)
        {:ok, new_uri}

      {:error, {:already_started, _pid}} ->
        {:ok, new_uri}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_template_content(uri) do
    target = Ezagent.URI.with_action(uri, :template, :read)

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: system_task_ctx()
         }) do
      {:ok, %{content: content}} -> {:ok, content}
      {:ok, content} when is_map(content) -> {:ok, content}
      other -> {:error, {:read_failed, other}}
    end
  end

  defp invoke_template_write(uri, _soul_body, slot_values, ctx) do
    target = Ezagent.URI.with_action(uri, :template, :write)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{
        content: %{
          name: Path.basename(URI.to_string(uri)),
          flavor: "cc",
          working_directory: "",
          default_caps: [],
          parent_template_uri: nil,
          created_by: ctx.caller,
          created_at: DateTime.utc_now(),
          soul_slot_values: slot_values
        }
      },
      ctx: ctx
    })
  end

  defp system_task_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("mix-task"),
      caps: Ezagent.SystemPrincipal.caps("system://mix-task"),
      reply: {:caller_inbox, self()}
    }
  end
end
