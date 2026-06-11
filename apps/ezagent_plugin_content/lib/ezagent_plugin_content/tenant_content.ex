defmodule EzagentPluginContent.TenantContent do
  @moduledoc """
  Public supply API: provision everything an agent of a given role needs.

  `provision_context/3` is the entry point consumed by the autoservice assembly.
  It reads from the tenant's published release (`TenantPaths.current_dir/1`) or,
  for admin preview, from the sandbox (`opts[:source] == :sandbox`).
  """

  alias EzagentPluginContent.{AgentsConfig, SkillIndexer, SoulRenderer, TenantPaths}

  @known_roles ~w(fast slow)

  @doc """
  Provision all context needed to run an agent of `role` for tenant `tid`.

  ## Options
    - `:source` — `:release` (default) or `:sandbox`

  ## Returns
    `{:ok, %{claude_md, system_prompt, agent_config, work_dir, kb_db_path, skills_dir}}`
    or `{:error, reason}`.
  """
  @spec provision_context(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def provision_context(tid, role, opts \\ []) when is_binary(tid) and is_binary(role) do
    # Check role before any filesystem work
    if role not in @known_roles do
      {:error, {:unknown_role, role}}
    else
      with {:ok, base} <- resolve_base(tid, opts) do
        do_provision(tid, role, base)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_base(tid, opts) do
    case Keyword.get(opts, :source, :release) do
      :release ->
        TenantPaths.current_dir(tid)

      :sandbox ->
        dir = TenantPaths.sandbox_dir(tid)

        if File.dir?(dir),
          do: {:ok, dir},
          else: {:error, :no_sandbox}
    end
  end

  defp do_provision(tid, role, base) do
    slots = load_slots(base)

    # Soul layers: platform skeleton base + optional tenant override
    skeleton_soul = Path.join([TenantPaths.skeleton_dir(), "souls", "customer_soul.md"])
    tenant_soul = Path.join(base, "souls/customer.md")

    soul_layers =
      [File.read!(skeleton_soul)] ++
        if(File.exists?(tenant_soul), do: [File.read!(tenant_soul)], else: [])

    rendered_soul = SoulRenderer.render(soul_layers, slots)

    skills_dir = Path.join(base, "skills")
    kb_path = Path.join(base, "kb/kb.db")
    kb_db_path = if File.exists?(kb_path), do: kb_path, else: nil

    with {:ok, role_content} <- build_role_content(role, base, rendered_soul, tid, skills_dir) do
      {:ok,
       Map.merge(role_content, %{
         agent_config: AgentsConfig.for_role(role),
         work_dir: TenantPaths.work_dir(tid, role),
         kb_db_path: kb_db_path,
         skills_dir: skills_dir
       })}
    end
  end

  defp load_slots(base) do
    # Per-role slot files will be added when multi-persona arrives;
    # for now a single customer.yaml covers all roles.
    yaml_path = Path.join(base, "slots/customer.yaml")

    case YamlElixir.read_from_file(yaml_path) do
      {:ok, parsed} when is_map(parsed) -> SoulRenderer.flatten(parsed)
      _ -> %{}
    end
  end

  defp build_role_content("slow", _base, rendered_soul, tid, skills_dir) do
    skill_index = SkillIndexer.build(skills_dir, tid)
    claude_md = preamble() <> rendered_soul <> "\n\n" <> skill_index

    {:ok, %{claude_md: claude_md, system_prompt: nil}}
  end

  defp build_role_content("fast", base, _rendered_soul, _tid, _skills_dir) do
    prompt_path = Path.join(base, "fast-deepseek-prompt/system_prompt.md")

    if File.exists?(prompt_path) do
      slots = load_slots(base)
      raw = File.read!(prompt_path)
      system_prompt = SoulRenderer.render(raw, slots)
      {:ok, %{claude_md: nil, system_prompt: system_prompt}}
    else
      {:error, {:missing_fast_prompt, prompt_path}}
    end
  end

  # Preamble verbatim from Stage-1 branch
  # (apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/cinnox_assets.ex
  #  `build_cc_claude_md/0` — role-based RESPONSE GATE variant, PR #715)
  defp preamble do
    """
    > **Runtime note (ezagent).** You are the CINNOX customer-service
    > agent running inside ezagent (claude-code via the esr-bridge channel) —
    > NOT inside the AutoService PV2 pipeline.
    >
    > **KB access — you HAVE a knowledge-base tool:**
    >   - **`kb_search`** (MCP server `cinnox-kb`): call it with a `query` to
    >     retrieve CINNOX / M800 product knowledge. Use it where the soul below
    >     tells you to consult the KB or call `kb_search`.
    >   - There is **no `<kb_context>` auto-injection** here. When you need
    >     product facts you must **call `kb_search` yourself**.
    >
    > **Skills are local files — use the Read tool:**
    >   - skills:      `plugins/cinnox/skills/customer/<name>/SKILL.md`
    >   - flow chunks: `plugins/cinnox/flow_chunks/*.md`
    >   - references:  `plugins/cinnox/references/*`
    >   - (no auto skill-loader; Read the SKILL.md yourself when a flow applies)
    >
    > **Replying:** the customer only sees text you send through your channel
    > reply. Once `kb_search` gives you the facts, answer **concisely and
    > directly** — do NOT loop on clarifying questions when you already have
    > enough to answer.
    >
    > **RESPONSE GATE — check BEFORE every reply:**
    > - You are in a group chat and receive the FULL chat history every time
    >   anyone sends a message — receiving a message is NOT itself a cue to reply.
    > - **You are this single CS bot**; your own agent URI is in the
    >   `EZAGENT_AGENT_URI` environment variable. **Answer the customer** —
    >   reply when the latest message is from the human customer (a `…/user/…`
    >   sender). (Single-bot CS: there is no other agent to defer to or wait for
    >   an @-mention from — the routing already delivers the customer's turn to you.)
    > - **NEVER respond to your own messages.** If the latest sender is yourself
    >   (your `EZAGENT_AGENT_URI`), stay completely silent — avoids a self-loop.
    > - **Stay silent once a human operator has taken over** the conversation
    >   (operator/takeover messages are not yours to answer).
    > - **NEVER re-answer a question you already replied to.** If the customer
    >   re-asks something you addressed, reply briefly and STOP.

    ---

    """
  end
end
