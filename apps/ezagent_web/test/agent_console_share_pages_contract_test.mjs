import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const staticRoot = path.resolve(__dirname, "../priv/static");
const rootPath = path.join(staticRoot, "index.html");
const journeyPath = path.join(staticRoot, "agent-console-journey/index.html");

assert.ok(fs.existsSync(rootPath), "missing static root landing page");
assert.ok(fs.existsSync(journeyPath), "missing full user journey page");

const rootHtml = fs.readFileSync(rootPath, "utf8");
const journeyHtml = fs.readFileSync(journeyPath, "utf8");

for (const marker of [
  'data-share-page="agent-console-demo-share-v1"',
  "Agent Console 分享入口",
  "设计确认 Demo",
  "完整用户旅程",
  "agent-console-demo/",
  "agent-console-journey/"
]) {
  assert.ok(rootHtml.includes(marker), `root page missing marker: ${marker}`);
}

for (const unwanted of ["favicon.ico", "robots.txt", "images/"]) {
  assert.ok(!rootHtml.includes(unwanted), `root page should not expose directory entry: ${unwanted}`);
}

for (const marker of [
  'data-journey-page="agent-console-user-journey-v1"',
  "完整用户旅程",
  "概览",
  "进入会话",
  "路由策略",
  "Manage-gate",
  "双主体审计",
  "routing-rule-add",
  ":manage_unauthorized",
  "{:unknown_member_role, role_name}",
  "agent-console-demo/"
]) {
  assert.ok(journeyHtml.includes(marker), `journey page missing marker: ${marker}`);
}

console.log("agent console share pages contract ok");
