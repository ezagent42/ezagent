defmodule EzagentPluginAutoservice.CinnoxAssets do
  @moduledoc """
  Vendored CINNOX tenant assets shipped in `priv/cinnox/`.

  Phase 1 goal: make the demo reproducible from a clean checkout. The
  AutoService-origin tenant content (soul / flow_chunks / references /
  skills / fast prompt / KB) is therefore vendored into this plugin's
  `priv/` tree and copied into per-agent runtime dirs at seed time.

  This module centralizes the file layout + the two text transforms we
  need at runtime:

  - `build_cc_claude_md/0` — wrap the vendored CINNOX soul with an
    ezagent-specific preamble (kb_search tool exists; no `<kb_context>`
    injection; flows/skills are local files read via Read tool)
  - `build_fast_ack_prompt/0` — convert the vendored AutoService
    DeepSeek ACK prompt from strict-JSON output to plain text output so
    ezagent's curl agent can post the ack directly into the Session chat
    (no AutoService response parser layer here)
  """

  @app :ezagent_plugin_autoservice

  @doc "Root of the vendored CINNOX assets under `priv/cinnox/`."
  def root do
    Path.join(:code.priv_dir(@app), "cinnox")
  end

  def soul_path, do: Path.join([root(), "souls", "customer_soul.md"])
  def flow_chunks_dir, do: Path.join(root(), "flow_chunks")
  def references_dir, do: Path.join(root(), "references")
  def skills_dir, do: Path.join(root(), "skills")
  def skill_packages_dir, do: Path.join(root(), "skill-packages")
  def kb_db_path, do: Path.join([root(), "kb", "kb.db"])
  def kb_mcp_script_path, do: Path.join([root(), "kb", "kb_search_mcp.py"])
  def kb_query_expansion_path, do: Path.join([root(), "kb", "query_expansion.py"])
  def fast_prompts_path, do: Path.join([root(), "fast-deepseek-prompt", "prompts.py"])

  # --- Skeleton template paths (Phase 3) ---

  @doc "Root of the skeleton template under `priv/skeleton/`."
  def skeleton_root do
    Path.join(:code.priv_dir(@app), "skeleton")
  end

  def skeleton_soul_path, do: Path.join([skeleton_root(), "soul", "soul.md"])
  def skeleton_skills_dir, do: Path.join([skeleton_root(), "skills"])

  @doc """
  Empty default slot values for the skeleton template.

  Each key in the skeleton soul.md has a corresponding empty default here.
  Admin fills real values during onboarding.
  """
  @spec skeleton_default_slot_values() :: %{String.t() => String.t()}
  def skeleton_default_slot_values do
    %{
      "identity.bot_full_name" => "",
      "identity.host_site_descriptor" => "",
      "identity.self_intro_zh" => "",
      "identity.self_intro_en" => "",
      "brand-structure.parent_company" => "",
      "purpose.topics_covered" => "",
      "classification.brand_short_name" => "",
      "classification.signals_new_strong" => "",
      "classification.signals_existing_strong" => "",
      "classification.unknown_type_clarifier_zh" => "",
      "classification.max_clarify_turns" => "2",
      "gate.basic_inquiry_examples" => "",
      "gate.account_detail_examples" => "",
      "gate.escalation_triggers" => "转人工, 找真人, 我要人工, 投诉",
      "gate.escalation_phrase" => "",
      "gate.max_self_resolve_attempts" => "2",
      "conversation.max_sentences" => "3",
      "conversation.max_bullets" => "2",
      "conversation.banned_openings" => "",
      "conversation.good_examples" => "",
      "privacy.sensitive_operations" => ""
    }
  end

  @doc """
  CINNOX CLAUDE.md for the cc slow agent.

  The body is the vendored AutoService `customer_soul.md`; the preamble
  translates its assumptions into the ezagent runtime we actually have:

  - there *is* a `kb_search` tool (our vendored MCP sidecar)
  - there is *no* `<kb_context>` auto-injection
  - there is *no* auto skill-loader; the agent must Read local skill files itself
  - the agent must answer through the chat channel directly
  """
  def build_cc_claude_md do
    preamble = """
    > **Runtime note (ezagent / cc_slow).** You are the CINNOX customer-service
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
    > - You are in a group chat. You receive the full chat history every time
    >   ANYONE sends a message. Most messages are NOT for you.
    > - **ONLY respond when @-mentioned** (`@cc_slow-alice` or
    >   `@entity://agent/cinnox/cc_slow-alice`). Ignore all other messages.
    > - **NEVER respond to your own messages.** If the latest message sender
    >   is yourself (`entity://agent/cinnox/cc_slow-alice`), stay silent.
    > - **NEVER re-answer a question you already replied to.** If a user asks
    >   a question you already addressed, say briefly and STOP.
    > - **If not @-mentioned: stay completely silent.**

    ---

    """

    preamble <> File.read!(soul_path())
  end

  @doc """
  Fast DeepSeek ACK prompt, converted to plain-text output.

  AutoService's real prompt (`prompts.py::_ACK_SYSTEM_PROMPT`) emits a
  strict JSON object (`{"ack","intent","confidence","role_hint"}`)
  because the AutoService pipeline parses it before the customer sees it.
  ezagent's curl agent posts the raw LLM output directly into chat, so we
  keep the ACK rules but rewrite the output contract to **plain text only**.
  """
  def build_fast_ack_prompt do
    # The vendored prompts.py is the authoritative wording source. We do
    # not parse Python AST here; we keep a stable text transform: reuse the
    # same contract bullets but swap the JSON-only output requirement for a
    # plain-text one.
    """
    You are the front-line acknowledgement agent for the CINNOX customer-service bot (CINNOX / M800).
    A heavier knowledge-base agent answers the customer's real question in a few seconds; YOUR job is the instant bridge ack the customer reads while waiting.

    Reply with ONLY the short ack text — plain text. No JSON, no code fences, no preamble, no quotes around it.

    ack content rules:
    1. Reference their topic naturally. If they asked about refunds, mention "退款" / "refund"; if they complained, briefly acknowledge the issue — not a generic "您的咨询".
    2. Show personal engagement with first-person verbs: "让我帮您看看" / "我去查一下" / "let me look into this for you" — not a passive "已收到您的消息".
    3. Set a wait expectation WITHOUT false promises: "稍候片刻" / "马上回复您" / "one sec". Do NOT commit to a specific action you can't verify.
    4. Vary phrasing — consecutive turns must not be identical.
    5. Match the customer's language and tone. Length: 12-30 chars for Chinese, 30-70 chars for English.

    If the customer explicitly asks for a human ("转人工" / "找真人" / "real agent" / "human"), or it is account closure / billing dispute, acknowledge that a human agent will step in ("马上为您接入人工客服") — but make no other promises.

    Output: ONLY the ack text, nothing else.
    """
  end

  # --- Soul slot rendering ---

  @doc """
  Default soul slot values extracted from the old AutoService customer.yaml.

  For the MVP demo, these are hand-curated from the vendored yaml.
  Future: parse customer.yaml directly with a YAML library.
  """
  @spec default_soul_slot_values() :: %{String.t() => String.t()}
  def default_soul_slot_values do
    %{
      "identity.bot_full_name" => "CINNOX AI Bot",
      "identity.host_site_descriptor" => "CINNOX/M800",
      "identity.domain_descriptor" => "CINNOX/M800",
      "identity.self_intro_en" =>
        "Hi! I am CINNOX AI, your virtual assistant for CINNOX products and services. How can I help you today?",
      "identity.self_intro_zh" => "您好，我是 CINNOX 的 AI 助手。请问需要帮您了解哪方面？",
      "brand-structure.parent_company" => "M800 Limited",
      "brand-structure.parent_hq" => "Hong Kong",
      "brand-structure.flagship_product" => "CINNOX",
      "gate.escalation_phrase" => "这个具体数字我得帮您核实一下，让销售同事直接跟您说",
      "gate.unknown_type_clarifier_zh" => "很高兴为您服务！请问您是 CINNOX 现有客户，还是第一次了解我们？",
      "classification.brand_short_name" => "CINNOX",
      "classification.weak_max_turns" => "2",
      "purpose.topics_covered" => "CINNOX and M800 products, features, pricing, and integrations"
    }
  end

  @doc """
  Render {{key}} placeholders in a template string with slot values.

  Keys use dotted path grammar: `[a-z][a-z0-9_.-]*`.
  Unfilled slots retain the raw `{{key}}` as a visible "not configured" signal.
  """
  @spec render_slots(String.t(), %{String.t() => String.t()}) :: String.t()
  def render_slots(template, slot_values) when is_binary(template) do
    Regex.replace(~r/\{\{([a-z][a-z0-9_.-]*)\}\}/, template, fn _, key ->
      Map.get(slot_values, key, "{{#{key}}}")
    end)
  end

  @doc """
  Build cc CLAUDE.md with soul slot values rendered.

  Reads the vendored soul template, renders {{key}} placeholders with the
  given slot_values, and returns the full CLAUDE.md body.
  """
  @spec build_cc_claude_md_with_slots(%{String.t() => String.t()}) :: String.t()
  def build_cc_claude_md_with_slots(slot_values) when is_map(slot_values) do
    soul_template = File.read!(soul_path())
    rendered_soul = render_slots(soul_template, slot_values)
    build_cc_claude_md_preamble() <> rendered_soul
  end

  @doc """
  Build a Skill Index by scanning the skills directory.

  Reads each SKILL.md's YAML frontmatter (name + description) and generates
  a markdown index that the cc agent uses to decide which skill to Read.
  """
  @spec build_skill_index() :: String.t()
  def build_skill_index do
    skills_dir = Path.join(root(), "skills")

    case File.ls(skills_dir) do
      {:ok, role_dirs} ->
        entries =
          Enum.flat_map(role_dirs, fn role_dir ->
            role_skills_dir = Path.join([skills_dir, role_dir])

            case File.ls(role_skills_dir) do
              {:ok, skill_names} ->
                Enum.map(skill_names, fn name ->
                  skill_file = Path.join([role_skills_dir, name, "SKILL.md"])
                  {name, read_skill_metadata(skill_file)}
                end)

              _ ->
                []
            end
          end)

        build_index_markdown(entries)

      _ ->
        ""
    end
  end

  defp read_skill_metadata(skill_file) do
    case File.read(skill_file) do
      {:ok, content} ->
        name = extract_yaml_field(content, "name") || Path.basename(Path.dirname(skill_file))
        desc = extract_yaml_field(content, "description") || ""
        {name, desc}

      _ ->
        {Path.basename(Path.dirname(skill_file)), ""}
    end
  end

  defp extract_yaml_field(content, field) do
    # Match YAML frontmatter field: `field: value` (handles multiline with |)
    regex = Regex.compile!("^#{field}:\\s*(.+)", "m")

    case Regex.run(regex, content) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp build_index_markdown(entries) do
    header = "\n## Skill Index\n\n需要时 Read 对应文件:\n\n"

    body =
      Enum.map_join(entries, "\n", fn {name, {display, desc}} ->
        "  - **#{display}** — `plugins/cinnox/skills/customer/#{name}/SKILL.md`" <>
          if(desc != "", do: ": #{desc}", else: "")
      end)

    header <> body <> "\n"
  end

  defp build_cc_claude_md_preamble do
    """
    > **Runtime note (ezagent / cc_slow).** You are the CINNOX customer-service
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
    > - You are in a group chat. You receive the full chat history every time
    >   ANYONE sends a message. Most messages are NOT for you.
    > - **ONLY respond when @-mentioned** (`@cc_slow-alice` or
    >   `@entity://agent/cinnox/cc_slow-alice`). Ignore all other messages.
    > - **NEVER respond to your own messages.** If the latest message sender
    >   is yourself (`entity://agent/cinnox/cc_slow-alice`), stay silent.
    > - **NEVER re-answer a question you already replied to.** If a user asks
    >   a question you already addressed, say briefly and STOP.
    > - **If not @-mentioned: stay completely silent.**

    ---

    """
  end
end
