#!/bin/bash
# E2E Demo Seeder — creates complete demo tenant with all content types.
# Run: bash scripts/e2e_seed_demo.sh

set -e
TID="demo-acme"
BASE="$HOME/.ezagent/default/tenants"
SB="$BASE/$TID/sandbox"

echo "=== Seeding demo tenant: $TID ==="

# 1. Create sandbox directory structure
mkdir -p "$SB/souls" "$SB/slots" "$SB/skills/customer" "$SB/kb/_sources/url" "$SB/kb/_sources/files" "$SB/config"

# 2. Write soul template
cat > "$SB/souls/customer.md" << 'SOUL'
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
SOUL
echo "  ✅ Soul: customer.md"

# 3. Write slots
cat > "$SB/slots/customer.yaml" << 'SLOTS'
brand_name: "Acme Corp"
industry: "零售电商"
service_hours: "7×24小时"
hotline: "400-888-9999"
return_policy: "7天无理由退换"
shipping_provider: "顺丰/京东物流"
SLOTS
echo "  ✅ Slots: customer.yaml"

# 4. Write fast agent prompt
cat > "$SB/config/fast_ack_prompt.md" << 'PROMPT'
你是 {{brand_name}} 的前线即时确认 Agent。
当客户发送消息后，你需要立即回复一个简短确认（12-30字），让客户知道消息已被接收，而后台知识库 Agent 正在处理。

回复规则：
1. 提及客户话题（退款/订单/物流等）
2. 展示正在处理："让我帮您看看" / "我去查一下"
3. 设定等待预期："稍候片刻" / "马上回复您"
4. 每次回复措辞要有变化
5. 中文12-30字
6. 客户要求转人工时，确认会转接

输出：仅回复文字，无JSON，无代码块。
PROMPT
echo "  ✅ Fast Agent Prompt"

# 5. Create skills
mkdir -p "$SB/skills/customer/order-lookup"
cat > "$SB/skills/customer/order-lookup/SKILL.md" << 'SKILL1'
# 订单查询 Skill

## 触发条件
用户询问订单状态、提供订单号、关键词：订单/物流/配送/快递

## 处理流程
1. 询问用户订单号（如未提供）
2. 查询订单系统获取状态
3. 返回：订单号、状态、预计送达时间
SKILL1
echo "  ✅ Skill: order-lookup"

mkdir -p "$SB/skills/customer/refund-policy"
cat > "$SB/skills/customer/refund-policy/SKILL.md" << 'SKILL2'
# 退换货政策 Skill

## 触发条件
用户询问退货/退款/换货，关键词：退款/退货/换货/不满意

## 政策要点
- 7天无理由退换（保持商品完好）
- 退款到账：1-3个工作日
- 换货运费由商家承担
SKILL2
echo "  ✅ Skill: refund-policy"

mkdir -p "$SB/skills/customer/product-recommend"
cat > "$SB/skills/customer/product-recommend/SKILL.md" << 'SKILL3'
# 产品推荐 Skill

## 触发条件
用户询问产品推荐、描述需求但未指定产品

## 推荐逻辑
1. 了解用户预算范围
2. 了解使用场景
3. 基于销量和评分推荐 Top 3
4. 提供对比要点
SKILL3
echo "  ✅ Skill: product-recommend"

# 6. Copy KB Python script
cp apps/ezagent_plugin_content/priv/skeleton/kb/kb_search_mcp.py "$SB/kb/" 2>/dev/null || echo "  ⚠️ kb_search_mcp.py not found in skeleton"

# 7. Add glossary.json for rebuild
cat > "$SB/kb/glossary.json" << 'GLOSSARY'
[{"term":"退货流程","definition":"客户申请退货→系统生成退货单→客户寄回→仓库验收→退款到账。时效：7天内申请，验收后1-3个工作日退款"},{"term":"换货流程","definition":"客户申请换货→系统生成换货单→客户寄回→仓库验收→发出新商品。时效：验收后1-2个工作日发货"},{"term":"VIP会员","definition":"银卡(满1000元)9.5折，金卡(满5000元)9折+免运费，钻石卡(满20000元)8.5折+免运费+专属客服"}]'
GLOSSARY
echo "  ✅ KB glossary.json"

echo ""
echo "=== Demo tenant '$TID' seeded! ==="
echo "  Soul:    $SB/souls/customer.md"
echo "  Slots:   $SB/slots/customer.yaml"
echo "  Skills:  3 skills"
echo "  Prompt:  $SB/config/fast_ack_prompt.md"
echo "  KB:      $SB/kb/"
echo ""
echo "Start: mix phx.server"
echo "Admin: /autoservice/admin?as=admin&workspace=$TID"
