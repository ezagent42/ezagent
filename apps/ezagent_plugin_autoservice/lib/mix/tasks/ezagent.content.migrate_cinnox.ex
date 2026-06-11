defmodule Mix.Tasks.Ezagent.Content.MigrateCinnox do
  @shortdoc "Migrate old CINNOX data from priv/cinnox/ to ~/.ezagent/default/tenants/cinnox/sandbox/"
  @moduledoc """
  One-shot idempotent data migration for CINNOX tenant onboarding.

  ## What it does

  1. Copies `souls/customer_soul.md` → `sandbox/souls/`
  2. Copies `skills/customer/*/SKILL.md` → `sandbox/skills/customer/` (flat .md, unify flow_chunks)
  3. Copies `kb/kb.db`, `glossary.json`, `escalation_keywords.json` → `sandbox/kb/`
  4. Reads `fast-deepseek-prompt/prompts.py` content → `sandbox/config/fast_ack_prompt.md`
  5. Generates `slot_values.yaml` in `sandbox/slots/` from old CinnoxAssets.default_soul_slot_values
  6. Calls `TenantProvisioner.create_tenant("cinnox", "CINNOX", industry: "cloud-comms")`
  7. Calls `CrEngine.ensure_active_cr("cinnox")` to create first CR

  ## Idempotency

  Re-running is safe: each step checks whether the target file or directory
  already exists and skips if it does. The task prints a summary at the end.

  ## Usage

      mix ezagent.content.migrate_cinnox
  """

  use Mix.Task

  alias EzagentPluginContent.Tenant.TenantProvisioner
  alias EzagentPluginContent.Tenant.TenantRuntime

  @impl Mix.Task
  def run(_argv) do
    # Ensure the app is started so ConfigStore / plugin APIs are available.
    Mix.Task.run("app.start", [])

    source_base = Path.join(:code.priv_dir(:ezagent_plugin_autoservice), "cinnox")
    tid = "cinnox"
    sandbox = TenantRuntime.sandbox_path(tid)
    results = []

    # --- Step 1: Copy souls/customer_soul.md → sandbox/souls/ ---
    results = step_copy_soul(source_base, sandbox, results)

    # --- Step 2: Copy skills/customer/*/SKILL.md → sandbox/skills/customer/ ---
    results = step_copy_skills(source_base, sandbox, results)

    # --- Step 3: Copy kb/kb.db, glossary.json, escalation_keywords.json → sandbox/kb/ ---
    results = step_copy_kb(source_base, sandbox, results)

    # --- Step 4: Copy fast-deepseek-prompt/prompts.py → sandbox/config/fast_ack_prompt.md ---
    results = step_copy_fast_ack(source_base, sandbox, results)

    # --- Step 5: Generate slot_values.yaml in sandbox/slots/ ---
    results = step_generate_slots(tid, results)

    # --- Step 6: TenantProvisioner.create_tenant ---
    results = step_provision_tenant(tid, results)

    # --- Step 7: CrEngine.ensure_active_cr ---
    results = step_ensure_cr(tid, results)

    # --- Summary ---
    print_summary(results)
  end

  # ── Step helpers ──

  defp step_copy_soul(source_base, sandbox, results) do
    src = Path.join(source_base, "souls/customer_soul.md")
    dst = Path.join(sandbox, "souls/customer_soul.md")

    if not File.exists?(src) do
      Mix.shell().info("[skip] soul: #{src} not found")
      results ++ [{:soul, :skip, "source not found"}]
    else
      results ++ [copy_file_idempotent(src, dst, :soul)]
    end
  end

  defp step_copy_skills(source_base, sandbox, results) do
    src_dir = Path.join(source_base, "skills/customer")
    dst_dir = Path.join(sandbox, "skills/customer")

    if not File.exists?(src_dir) do
      Mix.shell().info("[skip] skills: #{src_dir} not found")
      results ++ [{:skills, :skip, "source directory not found"}]
    else
      File.mkdir_p!(dst_dir)

      skill_results =
        src_dir
        |> File.ls!()
        |> Enum.filter(fn name ->
          File.dir?(Path.join(src_dir, name))
        end)
        |> Enum.flat_map(fn skill_name ->
          skill_src = Path.join([src_dir, skill_name, "SKILL.md"])
          skill_dst = Path.join(dst_dir, "#{skill_name}.md")

          case File.exists?(skill_src) do
            true ->
              [copy_file_idempotent(skill_src, skill_dst, :skill)]
            false ->
              # Try flow_chunks directory: unify into a single file
              chunks_dir = Path.join([src_dir, skill_name, "flow_chunks"])
              if File.exists?(chunks_dir) do
                [unify_flow_chunks(chunks_dir, skill_dst, skill_name)]
              else
                Mix.shell().info("[skip] skill/#{skill_name}: no SKILL.md or flow_chunks found")
                [{:skill, :skip, "no source for #{skill_name}"}]
              end
          end
        end)

      results ++ skill_results
    end
  end

  defp step_copy_kb(source_base, sandbox, results) do
    dst_dir = Path.join(sandbox, "kb")
    File.mkdir_p!(dst_dir)

    kb_files = ~w(kb.db glossary.json escalation_keywords.json)

    kb_results =
      Enum.map(kb_files, fn name ->
        src = Path.join(source_base, "kb/#{name}")
        dst = Path.join(dst_dir, name)
        copy_file_idempotent(src, dst, :kb)
      end)

    results ++ kb_results
  end

  defp step_copy_fast_ack(source_base, sandbox, results) do
    src = Path.join(source_base, "fast-deepseek-prompt/prompts.py")
    dst = Path.join(sandbox, "config/fast_ack_prompt.md")

    if not File.exists?(src) do
      Mix.shell().info("[skip] fast_ack_prompt: #{src} not found")
      results ++ [{:fast_ack, :skip, "source not found"}]
    else
      File.mkdir_p!(Path.dirname(dst))

      if File.exists?(dst) do
        Mix.shell().info("[skip] fast_ack_prompt.md already exists — idempotent")
        results ++ [{:fast_ack, :skip, "already exists"}]
      else
        content = File.read!(src)
        File.write!(dst, content)
        Mix.shell().info("[ok] fast_ack_prompt.md written")
        results ++ [{:fast_ack, :ok, dst}]
      end
    end
  end

  defp step_generate_slots(tid, results) do
    base_dir = TenantRuntime.base_dir()
    slots_dir = Path.join([base_dir, tid, "sandbox", "slots"])
    slots_file = Path.join(slots_dir, "customer.yaml")

    if File.exists?(slots_file) do
      Mix.shell().info("[skip] slot_values.yaml already exists — idempotent")
      results ++ [{:slots, :skip, "already exists"}]
    else
      File.mkdir_p!(slots_dir)

      # Generate default slot values from the old CinnoxAssets pattern.
      # These are the canonical default slot values for a cloud-communications
      # customer-service tenant (previously in CinnoxAssets.default_soul_slot_values).
      default_slots = %{
        "company_name" => "CINNOX",
        "industry" => "cloud-comms",
        "product_name" => "CINNOX",
        "support_hours" => "24/7",
        "greeting" => "Hello! Thank you for contacting CINNOX support. How may I assist you today?",
        "agent_name" => "CINNOX Support",
        "language" => "en",
        "tone" => "professional and helpful"
      }

      yaml = encode_yaml(default_slots)
      File.write!(slots_file, yaml)
      Mix.shell().info("[ok] slot_values.yaml generated at #{slots_file}")
      results ++ [{:slots, :ok, slots_file}]
    end
  end

  defp step_provision_tenant(tid, results) do
    # TenantProvisioner.create_tenant is idempotent via TenantConfig checks.
    case TenantProvisioner.create_tenant(tid, "CINNOX", industry: "cloud-comms") do
      {:ok, info} ->
        Mix.shell().info("[ok] tenant #{tid} provisioned: sandbox=#{info[:sandbox]}")
        results ++ [{:tenant, :ok, info}]

      {:error, reason} ->
        Mix.shell().error("[err] tenant #{tid} failed: #{inspect(reason)}")
        results ++ [{:tenant, :error, reason}]
    end
  end

  defp step_ensure_cr(tid, results) do
    # CrEngine is in ezagent_plugin_cr; it may not be started. Ensure CR deps are available.
    case Code.ensure_loaded(EzagentPluginCr.CrEngine) do
      {:module, _} ->
        :ok
      {:error, _} ->
        Application.ensure_all_started(:ezagent_plugin_cr)
    end

    case EzagentPluginCr.CrEngine.ensure_active_cr(tid) do
      {:ok, cr} ->
        Mix.shell().info("[ok] CR #{cr["cr_id"]} for #{tid} status=#{cr["status"]}")
        results ++ [{:cr, :ok, cr["cr_id"]}]

      {:error, reason} ->
        Mix.shell().error("[err] CR ensure failed: #{inspect(reason)}")
        results ++ [{:cr, :error, reason}]
    end
  end

  # ── Idempotency helpers ──

  defp copy_file_idempotent(src, dst, tag) do
    cond do
      not File.exists?(src) ->
        Mix.shell().info("[skip] #{tag}: source #{src} not found")
        {tag, :skip, "source not found"}

      File.exists?(dst) ->
        Mix.shell().info("[skip] #{tag}: #{dst} already exists — idempotent")
        {tag, :skip, "already exists"}

      true ->
        dst |> Path.dirname() |> File.mkdir_p!()
        File.cp!(src, dst)
        Mix.shell().info("[ok] #{tag}: #{dst}")
        {tag, :ok, dst}
    end
  end

  defp unify_flow_chunks(chunks_dir, dst, skill_name) do
    # Unify all files in flow_chunks/ into a single SKILL.md-equivalent file.
    if File.exists?(dst) do
      Mix.shell().info("[skip] skill/#{skill_name}: already exists — idempotent")
      {:skill, :skip, "already exists"}
    else
      chunk_files =
        chunks_dir
        |> File.ls!()
        |> Enum.sort()
        |> Enum.filter(&String.ends_with?(&1, ".md"))

      if chunk_files == [] do
        Mix.shell().info("[skip] skill/#{skill_name}: no .md chunks in flow_chunks")
        {:skill, :skip, "no chunks"}
      else
        unified =
          chunk_files
          |> Enum.map(fn name ->
            header = "\n## #{Path.basename(name, ".md")}\n\n"
            body = File.read!(Path.join(chunks_dir, name))
            header <> body
          end)
          |> Enum.join("\n")

        File.write!(dst, unified)
        Mix.shell().info("[ok] skill/#{skill_name}: #{length(chunk_files)} flow_chunks unified → #{dst}")
        {:skill, :ok, dst}
      end
    end
  end

  # ── YAML encoder ──

  defp encode_yaml(map, indent \\ 0)

  defp encode_yaml(map, indent) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      prefix = String.duplicate("  ", indent)

      if is_map(v) do
        "#{prefix}#{k}:\n#{encode_yaml(v, indent + 1)}"
      else
        "#{prefix}#{k}: #{escape_yaml_value(v)}"
      end
    end)
    |> Enum.join("\n")
  end

  defp encode_yaml(value, _indent), do: "#{value}"

  # Wrap values containing special YAML characters in quotes.
  defp escape_yaml_value(v) when is_binary(v) do
    if String.contains?(v, ":") or String.contains?(v, "#") or
       String.contains?(v, "[") or String.contains?(v, "]") or
       String.contains?(v, "{") or String.contains?(v, "}") or
       String.contains?(v, "&") or String.contains?(v, "*") or
       String.contains?(v, "!") or String.contains?(v, "|") or
       String.contains?(v, ">") or String.starts_with?(v, "\"") or
       String.starts_with?(v, "'") do
      inspect(v)
    else
      v
    end
  end

  defp escape_yaml_value(v), do: "#{v}"

  # ── Summary ──

  defp print_summary(results) do
    ok_count = Enum.count(results, &(elem(&1, 1) == :ok))
    skip_count = Enum.count(results, &(elem(&1, 1) == :skip))
    err_count = Enum.count(results, &(elem(&1, 1) == :error))

    Mix.shell().info("""

    ───────────────────────────────────────────────────────────────
    CINNOX Migration Summary
    ───────────────────────────────────────────────────────────────
      OK:   #{ok_count}
      Skip: #{skip_count}
      Err:  #{err_count}
      ───
      Total: #{length(results)}
    """)

    if err_count > 0 do
      Mix.shell().error("⚠  #{err_count} step(s) failed. Check the output above for details.")
    else
      Mix.shell().info("✅ Migration complete.")
    end
  end
end
