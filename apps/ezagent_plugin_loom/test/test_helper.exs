# `:live` 标记的测试要真实 LLM(DEEPSEEK_API_KEY)，默认排除；
# 跑 live: `mix test --include live`(并在进程环境提供 key)。
ExUnit.start(exclude: [:live])
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
