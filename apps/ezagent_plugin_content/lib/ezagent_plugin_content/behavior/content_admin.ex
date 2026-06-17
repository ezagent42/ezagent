defmodule EzagentPluginContent.Behavior.ContentAdmin do
  @moduledoc """
  Content admin Behavior — wraps soul/skill/KB/CR operations as dispatchable
  actions under the Workspace Kind. Registered via `CapabilityRegistry` only
  (stateless — no slice, no `behaviors/0` entry on the Kind).

  Dispatch target: `workspace://<tid>?action=content_admin.<action>`.
  The handler extracts the tenant ID from `ctx.self_uri` (workspace URI host).

  ## Design — stateless thin wrapper

  - NO persistent slice (`create/1` not defined — macro no-op default)
  - NO transients (no PIDs/refs/ETS)
  - Handlers delegate to existing store modules inline
  - Registered via `CapabilityRegistry.register/3` (BehaviorRegistry populated automatically)
  - NOT in Workspace Kind's `behaviors/0` — avoids core/domain changes

  ## What this adds over direct store calls

  - CapBAC enforcement (P15) — `required_caps/0` per action
  - Audit trail (P19) — telemetry `:start/:stop/:exception` via dispatch
  - Idempotency (P22) — webhook retry dedup via Invocation.dispatch
  - Agent programmability — MCP tools can call these actions via dispatch
  """

  use Ezagent.Lifecycle

  alias EzagentPluginContent.Soul.SoulStore
  alias EzagentPluginContent.Skill.SkillStore
  alias EzagentPluginContent.Kb.KbStore
  alias EzagentPluginContent.Tenant.TenantRuntime
  # ---- Action declarations ----

  action(:write_soul_slot,
    args: %{role: :string, key: :string, value: :string},
    returns: %{},
    caps: [:write_soul_slot],
    modes: [:call],
    description: "write a soul slot value for this workspace tenant's role"
  )

  action(:write_skill,
    args: %{role: :string, name: :string, content: :string},
    returns: %{},
    caps: [:write_skill],
    modes: [:call],
    description: "write a skill SKILL.md for this workspace tenant's role to sandbox"
  )

  action(:delete_skill,
    args: %{role: :string, name: :string},
    returns: %{},
    caps: [:write_skill],
    modes: [:call],
    description: "delete a skill directory from this workspace tenant's sandbox"
  )

  action(:upsert_kb,
    args: %{entry: :map},
    returns: %{},
    caps: [:write_kb],
    modes: [:call],
    description: "upsert a knowledge base entry for this workspace tenant's sandbox"
  )

  action(:delete_kb,
    args: %{id: :string},
    returns: %{},
    caps: [:write_kb],
    modes: [:call],
    description: "delete a knowledge base entry from this workspace tenant's sandbox"
  )

  action(:publish_cr,
    args: %{},
    returns: %{cr: :map},
    caps: [:publish_cr],
    modes: [:call],
    description: "publish the active change request — promote sandbox to release"
  )

  action(:preview_sandbox,
    args: %{role: :string},
    returns: %{session_uri: :uri, work_dir: :string},
    caps: [:preview_sandbox],
    modes: [:call],
    description: "create a sandbox preview session for this workspace tenant's role"
  )

  # ---- Re-route Phase 0 (2026-06-17): admin UI write ops as dispatch actions.
  # Same stateless thin-wrapper pattern; caps reuse the existing 5 atoms.
  # UI not wired yet (waits on caps grant PR #88/#154) — backend + tests only. ----

  action(:create_skill,
    args: %{role: :string, name: :string},
    returns: %{},
    caps: [:write_skill],
    modes: [:call],
    description: "create a new skill (SKILL.md template) in this tenant's sandbox"
  )

  action(:write_fast_prompt,
    args: %{content: :string},
    returns: %{},
    caps: [:write_soul_slot],
    modes: [:call],
    description: "write the fast agent ACK prompt (config/fast_ack_prompt.md) to sandbox"
  )

  action(:rebuild_kb,
    args: %{},
    returns: %{},
    caps: [:write_kb],
    modes: [:call],
    description: "rebuild the KB search index for this tenant's sandbox"
  )

  action(:revert_item,
    args: %{path: :string},
    returns: %{},
    caps: [:publish_cr],
    modes: [:call],
    description: "revert a single file from the current release back into sandbox"
  )

  # ---- Cap declarations ----

  def required_caps do
    %{
      write_soul_slot: Ezagent.Capability.cap(:workspace, __MODULE__, :write_soul_slot),
      write_skill: Ezagent.Capability.cap(:workspace, __MODULE__, :write_skill),
      delete_skill: Ezagent.Capability.cap(:workspace, __MODULE__, :write_skill),
      upsert_kb: Ezagent.Capability.cap(:workspace, __MODULE__, :write_kb),
      delete_kb: Ezagent.Capability.cap(:workspace, __MODULE__, :write_kb),
      publish_cr: Ezagent.Capability.cap(:workspace, __MODULE__, :publish_cr),
      preview_sandbox: Ezagent.Capability.cap(:workspace, __MODULE__, :preview_sandbox),
      # Re-route Phase 0 — reuse the existing cap atoms by domain.
      create_skill: Ezagent.Capability.cap(:workspace, __MODULE__, :write_skill),
      write_fast_prompt: Ezagent.Capability.cap(:workspace, __MODULE__, :write_soul_slot),
      rebuild_kb: Ezagent.Capability.cap(:workspace, __MODULE__, :write_kb),
      revert_item: Ezagent.Capability.cap(:workspace, __MODULE__, :publish_cr)
    }
  end

  def data_owner(_), do: :any

  # ---- Handlers (stateless — no ctx.read, no {:set, ...} effects) ----

  def handle_write_soul_slot(args, ctx) do
    %{role: role, key: key, value: value} = args
    {:ok, tid} = extract_tid(ctx)
    base_dir = TenantRuntime.base_dir()

    with :ok <- SoulStore.write_slots(base_dir, tid, role, %{key => value}, :sandbox),
         {:ok, _cr} <- lazy_cr(:ensure_active_cr, [tid]) do
      {:ok, %{}}
    end
  end

  def handle_write_skill(args, ctx) do
    %{role: role, name: name, content: content} = args
    {:ok, tid} = extract_tid(ctx)
    base_dir = TenantRuntime.base_dir()

    :ok = SkillStore.write(base_dir, tid, role, name, content)
    {:ok, %{}}
  end

  def handle_delete_skill(args, ctx) do
    %{role: role, name: name} = args
    {:ok, tid} = extract_tid(ctx)
    base_dir = TenantRuntime.base_dir()

    case SkillStore.delete(base_dir, tid, role, name) do
      :ok -> {:ok, %{}}
      {:error, _} = err -> err
    end
  end

  def handle_upsert_kb(args, ctx) do
    %{entry: entry} = args
    {:ok, tid} = extract_tid(ctx)
    kb_dir = kb_sandbox_dir(tid)

    case KbStore.upsert(kb_dir, entry) do
      :ok -> {:ok, %{}}
      {:error, _} = err -> err
    end
  end

  def handle_delete_kb(args, ctx) do
    %{id: id} = args
    {:ok, tid} = extract_tid(ctx)
    kb_dir = kb_sandbox_dir(tid)

    :ok = KbStore.delete(kb_dir, id)
    {:ok, %{}}
  end

  def handle_publish_cr(_args, ctx) do
    {:ok, tid} = extract_tid(ctx)

    case lazy_cr(:publish, [tid]) do
      {:ok, cr} -> {:ok, %{cr: cr}}
      {:error, _} = err -> err
    end
  end

  def handle_preview_sandbox(args, ctx) do
    %{role: role} = args
    {:ok, tid} = extract_tid(ctx)
    admin_uri = Map.get(ctx, :caller)

    # Lazy-load: autoservice depends on content, can't depend back.
    # Module name as atom avoids compile-time resolution.
    mod = Module.concat([EzagentPluginAutoservice, AutoserviceAssembly])

    if Code.ensure_loaded?(mod) and function_exported?(mod, :preview_provision, 3) do
      case apply(mod, :preview_provision, [tid, role, admin_uri]) do
        {:ok, %{session_uri: session_uri, work_dir: work_dir}} ->
          {:ok, %{session_uri: session_uri, work_dir: work_dir}}

        {:error, _} = err ->
          err
      end
    else
      {:error, :preview_unavailable}
    end
  end

  def handle_create_skill(args, ctx) do
    %{role: role, name: name} = args
    {:ok, tid} = extract_tid(ctx)
    base_dir = TenantRuntime.base_dir()

    template = "---\nname: #{name}\ndescription: \n---\n# #{name}\n"
    :ok = SkillStore.write(base_dir, tid, role, name, template)
    {:ok, %{}}
  end

  def handle_write_fast_prompt(args, ctx) do
    %{content: content} = args
    {:ok, tid} = extract_tid(ctx)
    path = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    _ = lazy_cr(:record_file_change, [tid, "config/fast_ack_prompt.md"])
    {:ok, %{}}
  end

  def handle_rebuild_kb(_args, ctx) do
    {:ok, tid} = extract_tid(ctx)

    case KbStore.rebuild(kb_sandbox_dir(tid)) do
      :ok -> {:ok, %{}}
      {:ok, _} -> {:ok, %{}}
      {:error, _} = err -> err
    end
  end

  def handle_revert_item(args, ctx) do
    %{path: path} = args
    {:ok, tid} = extract_tid(ctx)

    case lazy_cr(:revert_item, [tid, path]) do
      :ok -> {:ok, %{}}
      {:ok, _} -> {:ok, %{}}
      {:error, _} = err -> err
    end
  end

  # ---- Helpers ----

  # Lazy-load CrEngine — cr plugin depends on content, so we can't
  # depend back. Code.ensure_loaded? avoids compile-time cycles.
  defp lazy_cr(fun, args) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      {:error, :cr_engine_unavailable}
    end
  end

  defp extract_tid(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{scheme: "workspace", host: host} when host != "" and host != nil ->
        {:ok, host}

      %URI{scheme: "workspace"} ->
        {:error, :empty_workspace_host}

      other ->
        {:error, {:not_a_workspace_uri, other}}
    end
  end

  defp kb_sandbox_dir(tid) do
    Path.join([TenantRuntime.base_dir(), tid, "sandbox", "kb"])
  end
end
