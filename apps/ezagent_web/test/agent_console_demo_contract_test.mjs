import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const demoPath = path.resolve(__dirname, "../priv/static/agent-console-demo/index.html");
const html = fs.readFileSync(demoPath, "utf8");

const mustInclude = [
  'data-demo-contract="agent-console-operate-first-v1"',
  "独立静态设计确认 demo",
  "不接后端",
  "概览",
  "会话",
  "模板",
  "健康",
  "拓扑",
  "路由策略",
  "模板来源",
  "审计",
  "高级",
  "对象优先",
  "运营活会话优先",
  "read_topology",
  "routing-rule-add",
  "templates-read",
  "migrate_session",
  "Phase-1 ctx.caller",
  "Phase-2 ctx.caller",
  "authorized_operator_uri",
  "execution_principal_uri",
  "request_id",
  ":manage_unauthorized",
  "{:unknown_member_role, role_name}",
  ":session_not_live",
  "session://acme/storefront/storefront-7f3a",
  "template://acme/session/storefront@a1b2c3d4",
  "entity://acme/agent/cc_orchestrator-7f3a",
  "Create / Fork / Tag / publish 均禁用",
  "UI 不铸 cap"
];

for (const marker of mustInclude) {
  assert.ok(html.includes(marker), `missing marker: ${marker}`);
}

assert.ok(!html.includes("entity://agent/acme"), "must not use stale type-first entity URI");

console.log("agent console demo contract ok");
