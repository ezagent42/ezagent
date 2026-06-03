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

  @doc """
  CINNOX CLAUDE.md for the cc slow agent.

  The body is the vendored AutoService `customer_soul.md`; the preamble
  translates its assumptions into the ezagent runtime we actually have:

  - there *is* a `kb_search` tool (our vendored MCP sidecar)
  - there is *no* `<kb_context>` auto-injection
  - there is *no* auto skill-loader; the agent must Read local SKILL.md
    / flow / reference files itself
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
    > **Flows / skills / references are local files — use the Read tool:**
    >   - flows:      `plugins/cinnox/flow_chunks/*.md`
    >   - references: `plugins/cinnox/references/*`
    >   - skills:     `plugins/cinnox/skills/customer/<name>/SKILL.md`
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
end
