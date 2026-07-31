import fs from "node:fs";
import assert from "node:assert/strict";

const demo = new URL("../demo/MFU-多角色组织世界-v0.3.html", import.meta.url);
assert.ok(fs.existsSync(demo), "v0.3 multi-role demo must exist");
const html = fs.readFileSync(demo, "utf8");

for (const file of ["incubator.js", "school.js", "enterprise.js", "student.js"]) {
  const profile = new URL(`../role-profiles/${file}`, import.meta.url);
  assert.ok(fs.existsSync(profile), `missing role profile ${file}`);
  const source = fs.readFileSync(profile, "utf8");
  assert.match(source, /roleId:/, `${file} must define a role id`);
  assert.match(source, /initial:/, `${file} must define initial workspace data`);
}

for (const id of [
  "demo-role-controller",
  "demo-role-select",
  "reset-current-role",
  "reset-all-demo",
  "market-filters"
]) assert.match(html, new RegExp(`id=["']${id}["']`), `missing #${id}`);

for (const expectedText of [
  "ROLE_PROFILES",
  "mfu-v03-world",
  "mfu-v03-role-",
  "mfu-v03-active-role",
  "switchRole",
  "resetCurrentRole",
  "resetAllDemo",
  "history.replaceState",
  "URLSearchParams",
  "marketFilter",
  "setMarketFilter",
  "推荐",
  "全部",
  "教育与校园",
  "消费与零售",
  "内容与品牌",
  "软件与 AI",
  "社会创新",
  "节点外包",
  "我发布的"
]) assert.ok(html.includes(expectedText), `missing multi-role behavior: ${expectedText}`);

assert.ok(!html.includes('const STORAGE_ID="mfu-pasture-v02c"'), "v0.3 must not reuse v0.2 storage");
assert.ok(html.includes("workshopChoices"), "organization workshop must use current role resources");
assert.ok(!html.includes('const choices=[{id:"person-ahe"'), "workshop must not hard-code incubator resources");
assert.ok(!html.includes('id="role-view-notice"'), "duplicate current-role label must be removed");
assert.ok(!html.includes('onclick="resetGame()"'), "in-game reset button must be removed");
assert.ok(html.includes("我的 MVO"), "shared organization area must use the role-neutral MVO name");
assert.ok(html.includes("Minimum Valuable Organization"), "MVO must have a plain-language explanation");
assert.ok(html.includes("org-scroll"), "MVO cards must scroll independently from the fixed header");
assert.ok(html.includes('id="organization-current-project"'), "MVO detail must expose its current project directly");
assert.ok(!html.includes('["task","进行中的项目"]'), "current project must not remain a detail tab");
console.log("MFU multi-role v0.3 static contract passed");
