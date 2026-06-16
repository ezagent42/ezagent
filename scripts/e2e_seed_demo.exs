#!/usr/bin/env elixir
# E2E Demo Seeder — initializes a complete demo tenant with all content types.
# Run: mix run scripts/e2e_seed_demo.exs

alias EzagentPluginContent.Tenant.{TenantProvisioner, TenantRuntime}
alias EzagentPluginContent.Kb.KbStore
alias EzagentPluginContent.Skill.SkillStore
alias EzagentPluginContent.Soul.SoulStore

tid = "demo-acme"
base_dir = TenantRuntime.base_dir()
sandbox = TenantRuntime.sandbox_path(tid)
IO.puts("Seeding demo tenant: #{tid}")

# 1. Create tenant sandbox
IO.puts("1. Creating tenant sandbox...")
case TenantProvisioner.create_tenant(tid, "Acme Corp", industry: "零售电商") do
  {:ok, _} -> IO.puts("   ✅ Tenant created")
  {:error, reason} -> IO.puts("   ⚠️ #{inspect(reason)} (may already exist)")
end

# 2. Write soul template (industry-specific)
IO.puts("2. Writing soul template...")
soul_content = """
# {{brand_name}} 智能客服 Agent

你是 {{brand_name}} 的智能客服助手，专注于 {{industry}} 行业。

## 品牌信息
- 品牌名称：{{brand_name}}
- 行业：{{industry}}
- 服务时间：{{service_hours}}
- 客服热线：{{hotline}}

## 服务范围
1. 订单查询与跟踪
2. 退换货处理
3. 产品咨询
4. 价格与优惠查询
5. 投诉与建议

## 回复原则
1. **友好专业**：始终保持礼貌、耐心的态度
2. **准确高效**：优先使用知识库中的准确信息
3. **主动解决**：无法直接回答时，提供替代方案或引导转人工
4. **简洁明了**：回复控制在3-5句话内，避免冗长

## 开场白
您好！欢迎来到{{brand_name}}，我是您的智能客服小助手。请问有什么可以帮助您的？
"""
soul_dir = Path.join([sandbox, "souls"])
File.mkdir_p!(soul_dir)
File.write!(Path.join(soul_dir, "customer.md"), soul_content)
IO.puts("   ✅ Soul template written (customer.md)")

# 3. Write slots
IO.puts("3. Writing slot values...")
slots_content = """
brand_name: "Acme Corp"
industry: "零售电商"
service_hours: "7×24小时"
hotline: "400-888-9999"
return_policy: "7天无理由退换"
shipping_provider: "顺丰/京东物流"
"""
slots_dir = Path.join([sandbox, "slots"])
File.mkdir_p!(slots_dir)
File.write!(Path.join(slots_dir, "customer.yaml"), slots_content)
IO.puts("   ✅ Slots written (customer.yaml)")

# 4. Write fast agent prompt
IO.puts("4. Writing fast agent prompt...")
fast_prompt = """
You are the front-line acknowledgement agent for {{brand_name}}.
A heavier knowledge-base agent answers the customer's real question in a few seconds; YOUR job is the instant bridge ack the customer reads while waiting.

Reply with ONLY the short ack text — plain text. No JSON, no code fences.

ack rules:
1. Reference topic naturally (退款/订单/物流)
2. Show personal engagement: "让我帮您看看" / "我去查一下"
3. Set wait expectation: "稍候片刻" / "马上回复您"
4. Vary phrasing between turns
5. Length: 12-30 chars Chinese
6. If customer asks for human ("转人工"): acknowledge human will help
"""
config_dir = Path.join([sandbox, "config"])
File.mkdir_p!(config_dir)
File.write!(Path.join(config_dir, "fast_ack_prompt.md"), fast_prompt)
IO.puts("   ✅ Fast agent prompt written")

# 5. Create skills
IO.puts("5. Creating skills...")
skills = %{
  "order-lookup" => """
# 订单查询 Skill

## 触发条件
- 用户询问订单状态
- 用户提供订单号
- 关键词：订单、物流、配送、快递

## 处理流程
1. 询问用户订单号（如未提供）
2. 查询订单系统获取状态
3. 返回：订单号、状态、预计送达时间
4. 如订单异常，提供客服电话

## 话术示例
"您的订单#{order_id}目前状态为#{status}，预计#{delivery_date}送达。如需帮助，请随时联系。"
""",
  "refund-policy" => """
# 退换货政策 Skill

## 触发条件
- 用户询问退货/退款/换货
- 关键词：退款、退货、换货、不满意

## 政策要点
- 7天无理由退换（保持商品完好）
- 退款到账时间：1-3个工作日
- 换货运费由商家承担
- 特殊商品（内衣、食品）不支持退换

## 处理流程
1. 确认商品是否在退换期内
2. 告知退换流程
3. 生成退换货单号
""",
  "product-recommend" => """
# 产品推荐 Skill

## 触发条件
- 用户询问产品推荐
- 用户描述需求但未指定产品
- 关键词：推荐、哪个好、性价比

## 推荐逻辑
1. 了解用户预算范围
2. 了解使用场景
3. 基于销量和评分推荐 Top 3
4. 提供对比要点

## 话术示例
"根据您的需求，我为您推荐以下产品：1) #{product_a} - #{price_a}元，适合#{scenario_a} 2) #{product_b}..."
"""
}

Enum.each(skills, fn {name, content} ->
  SkillStore.write(base_dir, tid, "customer", name, content)
  IO.puts("   ✅ Skill: #{name}")
end)

# 6. Add KB entries (manual + URL fetch)
IO.puts("6. Adding KB entries...")
kb_dir = Path.join([sandbox, "kb"])
File.mkdir_p!(kb_dir)

# Pre-create the Python script if not present
py_script = Path.join(kb_dir, "kb_search_mcp.py")
unless File.exists?(py_script) do
  skeleton_script = Path.join([Application.app_dir(:ezagent_plugin_content), "priv", "skeleton", "kb", "kb_search_mcp.py"])
  if File.exists?(skeleton_script) do
    File.cp!(skeleton_script, py_script)
  end
end

# Manual KB entry
KbStore.upsert(kb_dir, %{
  "id" => "kb-001",
  "title" => "退换货流程说明",
  "content" => "客户申请退换货后，系统自动生成退换货单号。客户需在7天内将商品寄回（使用原包装）。仓库收到退货后1-2个工作日验收，验收通过后1-3个工作日退款到原支付账户。换货在验收通过后1-2个工作日发出新商品。退换货运费由Acme Corp承担（质量问题）或客户承担（非质量问题）。"
})
IO.puts("   ✅ KB manual entry: kb-001")

KbStore.upsert(kb_dir, %{
  "id" => "kb-002",
  "title" => "VIP会员权益",
  "content" => "VIP会员分为三个等级：银卡（消费满1000元）、金卡（消费满5000元）、钻石卡（消费满20000元）。银卡享9.5折，金卡享9折+免运费，钻石卡享8.5折+免运费+专属客服+优先发货。会员积分1元=1积分，积分可兑换优惠券或商品。"
})
IO.puts("   ✅ KB manual entry: kb-002")

KbStore.upsert(kb_dir, %{
  "id" => "kb-003",
  "title" => "支付方式说明",
  "content" => "支持支付方式：微信支付、支付宝、银联卡、Apple Pay、花呗分期（3/6/12期）。花呗分期手续费：3期免手续费，6期0.6%/期，12期0.8%/期。国际订单支持Visa/Mastercard。企业客户支持对公转账（联系客服开通）。"
})
IO.puts("   ✅ KB manual entry: kb-003")

# 7. Create a dummy CR entry
IO.puts("7. Seeding CR record...")
cr_data = %{
  "cr_id" => "cr-demo-2026-001",
  "tenant_id" => tid,
  "created_by" => "system://cr-engine",
  "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
  "status" => "published",
  "published_version" => "v1",
  "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
}
# Write CR via TenantConfig's ConfigStore (if available)
cr_module = EzagentPluginContent.Tenant.TenantConfig
if Code.ensure_loaded?(cr_module) and function_exported?(cr_module, :read_cr, 2) do
  # CR is created by CrEngine.ensure_active_cr
  IO.puts("   ℹ️ CR managed by CrEngine, use TenantAdminLive Publish tab")
end

IO.puts("\n=== Demo tenant '#{tid}' seeded successfully! ===")
IO.puts("  • Soul: customer.md (#{String.length(soul_content)} chars)")
IO.puts("  • Slots: customer.yaml (#{Enum.count(String.split(slots_content, "\n"))} lines)")
IO.puts("  • Skills: #{map_size(skills)} (order-lookup, refund-policy, product-recommend)")
IO.puts("  • KB entries: 3 manual")
IO.puts("  • Fast Agent prompt: configured")
IO.puts("\nStart server: mix phx.server")
IO.puts("Admin pages:")
IO.puts("  Master Dashboard: /admin/autoservice?as=admin&workspace=system")
IO.puts("  Tenant Admin:     /autoservice/admin?as=admin&workspace=#{tid}")
IO.puts("  CR Dashboard:     /admin/autoservice/tenants/#{tid}/cr?as=admin&workspace=system")
