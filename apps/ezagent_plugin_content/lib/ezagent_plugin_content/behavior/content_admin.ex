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
    caps: [:delete_skill],
    modes: [:call],
    description: "delete a skill directory from this workspace tenant's sandbox"
  )

  action(:upsert_kb,
    args: %{entry: :map},
    returns: %{},
    caps: [:upsert_kb],
    modes: [:call],
    description: "upsert a knowledge base entry for this workspace tenant's sandbox"
  )

  action(:delete_kb,
    args: %{id: :string},
    returns: %{},
    caps: [:delete_kb],
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
  # Same stateless thin-wrapper pattern; each action declares its own cap atom
  # (action-axis A5 — action_of must match the action name). UI not wired yet
  # (waits on caps grant PR #88/#154) — backend + tests only. ----

  action(:create_skill,
    args: %{role: :string, name: :string},
    returns: %{},
    caps: [:create_skill],
    modes: [:call],
    description: "create a new skill (SKILL.md template) in this tenant's sandbox"
  )

  action(:write_fast_prompt,
    args: %{content: :string},
    returns: %{},
    caps: [:write_fast_prompt],
    modes: [:call],
    description: "write the fast agent ACK prompt (config/fast_ack_prompt.md) to sandbox"
  )

  action(:rebuild_kb,
    args: %{},
    returns: %{},
    caps: [:rebuild_kb],
    modes: [:call],
    description: "rebuild the KB search index for this tenant's sandbox"
  )

  action(:revert_item,
    args: %{path: :string},
    returns: %{},
    caps: [:revert_item],
    modes: [:call],
    description: "revert a single file from the current release back into sandbox"
  )

  # ---- Re-route Phase 0 batch 2 (2026-06-17): remaining admin-UI write ops.
  # Covers full-file soul/slots writes, KB url-fetch + file-ingest, and
  # release rollback. Same stateless pattern; per-action cap atoms (A5). ----

  action(:write_soul,
    args: %{role: :string, content: :string},
    returns: %{},
    caps: [:write_soul],
    modes: [:call],
    description: "write the full soul markdown (souls/<role>.md) to this tenant's sandbox"
  )

  action(:write_slots,
    args: %{role: :string, content: :string},
    returns: %{},
    caps: [:write_slots],
    modes: [:call],
    description: "write the full slots YAML (slots/<role>.yaml) to this tenant's sandbox"
  )

  action(:fetch_kb_url,
    args: %{url: :string},
    returns: %{},
    caps: [:fetch_kb_url],
    modes: [:call],
    description: "fetch a URL into the KB for this tenant's sandbox"
  )

  action(:ingest_kb_file,
    args: %{file_path: :string},
    returns: %{},
    caps: [:ingest_kb_file],
    modes: [:call],
    description: "ingest a local file into the KB for this tenant's sandbox"
  )

  action(:rollback_version,
    args: %{version: :string},
    returns: %{},
    caps: [:rollback_version],
    modes: [:call],
    description: "roll the current release symlink back to a prior version"
  )

  # ---- Cap declarations ----

  # Each entry's cap action_of MUST equal its action key (capability-action-axis
  # A5, SPEC 2026-05-27) — a cap named for one action may not gate a differently
  # named action. Per-action atoms preserve fine-grained grants; a `:any`
  # wildcard grant (Phase 1) still subsumes them all via check_action_wildcard.
  def required_caps do
    %{
      write_soul_slot: Ezagent.Capability.cap(:workspace, __MODULE__, :write_soul_slot),
      write_skill: Ezagent.Capability.cap(:workspace, __MODULE__, :write_skill),
      delete_skill: Ezagent.Capability.cap(:workspace, __MODULE__, :delete_skill),
      upsert_kb: Ezagent.Capability.cap(:workspace, __MODULE__, :upsert_kb),
      delete_kb: Ezagent.Capability.cap(:workspace, __MODULE__, :delete_kb),
      publish_cr: Ezagent.Capability.cap(:workspace, __MODULE__, :publish_cr),
      preview_sandbox: Ezagent.Capability.cap(:workspace, __MODULE__, :preview_sandbox),
      # Re-route Phase 0.
      create_skill: Ezagent.Capability.cap(:workspace, __MODULE__, :create_skill),
      write_fast_prompt: Ezagent.Capability.cap(:workspace, __MODULE__, :write_fast_prompt),
      rebuild_kb: Ezagent.Capability.cap(:workspace, __MODULE__, :rebuild_kb),
      revert_item: Ezagent.Capability.cap(:workspace, __MODULE__, :revert_item),
      # Re-route Phase 0 batch 2.
      write_soul: Ezagent.Capability.cap(:workspace, __MODULE__, :write_soul),
      write_slots: Ezagent.Capability.cap(:workspace, __MODULE__, :write_slots),
      fetch_kb_url: Ezagent.Capability.cap(:workspace, __MODULE__, :fetch_kb_url),
      ingest_kb_file: Ezagent.Capability.cap(:workspace, __MODULE__, :ingest_kb_file),
      rollback_version: Ezagent.Capability.cap(:workspace, __MODULE__, :rollback_version)
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

  def handle_write_soul(%{role: role, content: content}, ctx) do
    {:ok, tid} = extract_tid(ctx)
    rel = Path.join(["souls", "#{role}.md"])
    write_sandbox_file(tid, rel, content)
  end

  def handle_write_slots(%{role: role, content: content}, ctx) do
    {:ok, tid} = extract_tid(ctx)

    with :ok <- validate_yaml(content) do
      write_sandbox_file(tid, Path.join(["slots", "#{role}.yaml"]), content)
    end
  end

  def handle_fetch_kb_url(%{url: url}, ctx) do
    {:ok, tid} = extract_tid(ctx)

    case KbStore.fetch_url(kb_sandbox_dir(tid), url) do
      :ok ->
        _ = lazy_cr(:ensure_active_cr, [tid])
        {:ok, %{}}

      {:error, _} = err ->
        err
    end
  end

  def handle_ingest_kb_file(%{file_path: file_path}, ctx) do
    {:ok, tid} = extract_tid(ctx)

    case KbStore.ingest_file(kb_sandbox_dir(tid), file_path) do
      :ok ->
        _ = lazy_cr(:ensure_active_cr, [tid])
        {:ok, %{}}

      {:error, _} = err ->
        err
    end
  end

  def handle_rollback_version(%{version: version}, ctx) do
    {:ok, tid} = extract_tid(ctx)

    case lazy_mod(EzagentPluginCr.CrRollback, :rollback, [tid, version]) do
      :ok -> {:ok, %{}}
      {:ok, _} -> {:ok, %{}}
      {:error, _} = err -> err
    end
  end

  # ---- Helpers ----

  defp write_sandbox_file(tid, rel_path, content) do
    path = Path.join(TenantRuntime.sandbox_path(tid), rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    _ = lazy_cr(:record_file_change, [tid, rel_path])
    {:ok, %{}}
  end

  defp validate_yaml(content) do
    if Code.ensure_loaded?(YamlElixir) do
      case YamlElixir.read_from_string(content) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:invalid_yaml, reason}}
      end
    else
      :ok
    end
  end

  # Generic lazy module call — same cycle-avoidance rationale as lazy_cr,
  # for cr-plugin modules other than CrEngine (e.g. CrRollback).
  defp lazy_mod(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      {:error, :module_unavailable}
    end
  end

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
