# MFU World Market and Node Outsourcing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable “My Workspace / World” shell, distinguish market orders from owned orders, and make MVO execution and outsourcing visible at organization-node level.

**Architecture:** Keep the existing single-file HTML prototype and shared browser state. Add `marketOrders`, `worldFeed`, and per-organization `nodeStates`; move an order between world and workspace through explicit state transitions, while node outsourcing creates a linked market order that can return a result to its source node.

**Tech Stack:** Single-file HTML, CSS, browser JavaScript, localStorage, Node.js static-contract tests, Playwright browser-flow tests.

## Global Constraints

- Modify `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`; do not create a replacement demo.
- Use the top-level labels `我的工作台` and `世界`.
- `订单板` contains only orders already held by the current player.
- `订单市场` contains only orders not yet held by the current player.
- Remove the old one-click `外包子任务` action and its automatic ¥400 / +10% effect.
- A node outsourcing order must retain links to its source order, MVO, and node.
- First version uses fixed market data and simulated external acceptance; no real multiplayer.
- Preserve existing assignment, workshop, acceptance, invoicing, payment, growth, and fixed-height resource dock flows.
- No new dependencies.
- Ask ruihua before every commit or push.

---

### Task 1: Add the reusable workspace/world shell

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Produces: `setMainTab(tab: "workspace" | "world") -> void`
- Produces: `renderMainView() -> void`
- Produces: DOM selectors `#main-tabs`, `#workspace-view`, `#world-view`
- Consumes: existing `renderTodo`, `renderPasture`, `renderActions`, `renderInventory`.

- [ ] **Step 1: Add failing static-contract checks**

Add:

```js
for (const token of [
  "activeMainTab",
  "setMainTab",
  "renderMainView",
  "我的工作台",
  "世界",
  'id="main-tabs"',
  'id="workspace-view"',
  'id="world-view"'
]) assert.ok(html.includes(token), `missing main world shell: ${token}`);
```

- [ ] **Step 2: Run the static test and verify failure**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
```

Expected: FAIL on `activeMainTab`.

- [ ] **Step 3: Wrap the current game as the workspace**

Add `activeMainTab:"workspace"` to initial state and normalize old saves:

```js
next.activeMainTab ||= "workspace";
```

Wrap the existing three-column game and resource dock in `#workspace-view`. Add:

```html
<nav id="main-tabs" class="main-tabs">
  <button data-main-tab="workspace" onclick="setMainTab('workspace')">我的工作台</button>
  <button data-main-tab="world" onclick="setMainTab('world')">世界</button>
</nav>
```

Implement:

```js
function setMainTab(tab){
  state.activeMainTab=tab;
  save();
  renderMainView();
}
function renderMainView(){
  document.querySelector("#workspace-view").hidden=state.activeMainTab!=="workspace";
  document.querySelector("#world-view").hidden=state.activeMainTab!=="world";
  document.querySelectorAll("[data-main-tab]").forEach(button=>{
    button.classList.toggle("on",button.dataset.mainTab===state.activeMainTab);
  });
  if(state.activeMainTab==="world")renderWorld();
}
```

- [ ] **Step 4: Add browser navigation checks**

Add:

```js
await page.locator('[data-main-tab="world"]').click();
assert.equal(await page.locator("#world-view").isVisible(), true);
assert.equal(await page.locator("#workspace-view").isVisible(), false);
await page.locator('[data-main-tab="workspace"]').click();
assert.equal(await page.locator("#workspace-view").isVisible(), true);
```

- [ ] **Step 5: Run focused verification**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
awk '/<script>/{flag=1;next}/<\/script>/{flag=0}flag' mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html > /tmp/mfu-v02-script.js
node --check /tmp/mfu-v02-script.js
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/mvo-pasture-v02.browser.cjs
```

Expected: all PASS.

---

### Task 2: Add the world feed and market-order boundary

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Consumes: Task 1 `renderWorld`, shared `state.tasks`.
- Produces: `marketOrders: Array<MarketOrder>`
- Produces: `worldFeed: Array<WorldEvent>`
- Produces: `acceptMarketOrder(orderId: string) -> void`
- Produces: DOM selectors `#market-orders`, `#world-feed`, `#world-news`.

- [ ] **Step 1: Add failing market checks**

Add:

```js
for (const token of [
  "marketOrders",
  "worldFeed",
  "renderWorld",
  "acceptMarketOrder",
  "订单市场",
  "世界动态",
  "新闻与公告"
]) assert.ok(html.includes(token), `missing world market: ${token}`);
```

- [ ] **Step 2: Seed and normalize world data**

Add three fixed market orders:

```js
marketOrders:[
  {id:"market-campus-map",icon:"🗺️",name:"校园创业地图",client:"城南学院",reward:4800,difficulty:"普通",deadline:"5 天",kind:"external"},
  {id:"market-brand-test",icon:"🧃",name:"新饮品品牌测试",client:"谷雨食品",reward:6200,difficulty:"进阶",deadline:"7 天",kind:"external"},
  {id:"market-demo-day",icon:"🎤",name:"Demo Day 传播",client:"星谷加速器",reward:3600,difficulty:"普通",deadline:"4 天",kind:"external"}
],
worldFeed:[
  {id:"feed-1",type:"news",title:"夏季创业实践周开放报名",detail:"学校与企业将发布 24 个真实任务。"},
  {id:"feed-2",type:"activity",title:"远山内容 MVO 完成品牌交付",detail:"获得客户 A 级评价。"},
  {id:"feed-3",type:"notice",title:"系统公告",detail:"组织图验证算力本周限时八折。"}
]
```

Normalize:

```js
next.marketOrders ||= [];
next.worldFeed ||= [];
```

- [ ] **Step 3: Render the world page**

Implement `renderWorld()` with:

- market order cards in `#market-orders`;
- activity items in `#world-feed`;
- news and notices in `#world-news`;
- one `承接订单` button per available market order.

Do not render `state.tasks` in the market section.

- [ ] **Step 4: Move accepted orders into the workspace**

Implement:

```js
function acceptMarketOrder(orderId){
  const marketOrder=state.marketOrders.find(order=>order.id===orderId);
  if(!marketOrder)return;
  state.marketOrders=state.marketOrders.filter(order=>order.id!==orderId);
  state.tasks.push({
    ...marketOrder,
    reward:`¥${marketOrder.reward.toLocaleString()}`,
    status:"unassigned",
    orgId:null,
    quotedAmount:marketOrder.reward,
    invoiceStatus:"not_issued",
    paymentStatus:"not_due",
    cost:0,
    income:0
  });
  state.orderFilter="unassigned";
  save();
  renderWorld();
  toast("订单已进入我的工作台。");
}
```

- [ ] **Step 5: Verify the order boundary in Playwright**

Test:

```text
world order count decreases by one
workspace unassigned order count increases by one
accepted order appears only after switching to 我的工作台
```

- [ ] **Step 6: Run focused verification**

Run the static, script syntax, and browser commands from Task 1. Expected: PASS.

---

### Task 3: Show node-level project execution

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Consumes: existing `org.steps`, `org.gems`, `openOrgTab`.
- Produces: `normalizeNodeStates(org) -> Array<OrgNodeState>`
- Produces: `projectGraphMarkup(org) -> string`
- Produces: `openProjectNode(orgId: string, nodeId: string) -> void`
- Produces: DOM selector `[data-project-node]`.

- [ ] **Step 1: Add failing node-state assertions**

Add:

```js
for (const token of [
  "nodeStates",
  "normalizeNodeStates",
  "projectGraphMarkup",
  "openProjectNode",
  "已完成",
  "正在运行",
  "未开始",
  "等待外部承接"
]) assert.ok(html.includes(token), `missing node execution state: ${token}`);
```

Also assert the old interaction is absent:

```js
assert.ok(!html.includes(">📮 外包子任务</button>"), "old instant outsourcing button remains");
```

- [ ] **Step 2: Remove the old button and behavior**

Remove the `外包子任务` button from the project tab. Remove `subcontractTask()` and its ¥400 / +10% behavior. Remove its positive static test.

- [ ] **Step 3: Normalize node execution state**

Implement:

```js
function normalizeNodeStates(org){
  if(org.nodeStates?.length===org.steps.length)return org.nodeStates;
  const activeIndex=org.status==="idle"?-1:Math.min(org.steps.length-1,Math.floor(org.progress/Math.max(1,100/org.steps.length)));
  org.nodeStates=org.steps.map((label,index)=>({
    id:`${org.id}-node-${index}`,
    label,
    resource:org.gems[index],
    status:index<activeIndex?"completed":index===activeIndex?"running":"pending",
    externalOrderId:null,
    result:index<activeIndex?"阶段成果已保存":null
  }));
  return org.nodeStates;
}
```

Map labels:

```js
const NODE_STATUS={
  completed:"已完成",
  running:"正在运行",
  pending:"未开始",
  outsourced:"等待外部承接"
};
```

- [ ] **Step 4: Replace the project tab content**

In `openOrgTab(id,"task")`, render `projectGraphMarkup(org)` before chat. Each node must show resource, state, and click handler:

```html
<button data-project-node="..." onclick="openProjectNode('org-id','node-id')">...</button>
```

Keep the project progress bar and chat below the graph.

- [ ] **Step 5: Keep nodes synchronized with work progression**

After `assignTask`, `advanceWork`, `rejectDelivery`, and `completeSettlement`, call a shared `syncNodeProgress(org)` that:

- marks nodes before current progress as `completed`;
- marks the current node as `running`;
- preserves `outsourced` nodes;
- marks all nodes `completed` at review/settlement/completion.

- [ ] **Step 6: Verify node states**

Browser test:

```text
open a running MVO
open 进行中的项目
assert at least one completed, one running, and one pending node
advance work
assert the running state moves forward
```

- [ ] **Step 7: Run focused verification**

Run the static, script syntax, and browser commands from Task 1. Expected: PASS.

---

### Task 4: Publish and resolve node outsourcing orders

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Consumes: Task 2 `marketOrders`, Task 3 node states.
- Produces: `openNodeOutsourceForm(orgId, nodeId) -> void`
- Produces: `publishNodeOrder(orgId, nodeId) -> void`
- Produces: `simulateExternalAcceptance(orderId) -> void`
- Produces: `completeExternalNodeOrders() -> void`.

- [ ] **Step 1: Add failing outsourcing assertions**

Add:

```js
for (const token of [
  "openNodeOutsourceForm",
  "publishNodeOrder",
  "simulateExternalAcceptance",
  "completeExternalNodeOrders",
  "发布为订单",
  "模拟外部玩家承接"
]) assert.ok(html.includes(token), `missing node outsourcing: ${token}`);
```

- [ ] **Step 2: Add the node detail and publishing form**

`openProjectNode` must show node input, output, resources, and status. For a `running` or `pending` node without an external order, show:

```html
<button id="publish-node-order" onclick="openNodeOutsourceForm(orgId,nodeId)">发布为订单</button>
```

The form pre-fills:

- name: `${org.name} · ${node.label}`;
- output: `完成“${node.label}”并返回可接入原任务流的成果`;
- budget: `600`;
- deadline: `2 天`.

- [ ] **Step 3: Publish the linked market order**

Implement:

```js
function publishNodeOrder(orgId,nodeId){
  const org=state.orgs.find(item=>item.id===orgId);
  const node=normalizeNodeStates(org).find(item=>item.id===nodeId);
  const sourceOrder=state.tasks.find(item=>item.orgId===orgId&&item.status==="running");
  const orderId=`outsource-${Date.now()}`;
  state.marketOrders.unshift({
    id:orderId,
    icon:"🔗",
    name:`${org.name} · ${node.label}`,
    client:org.name,
    reward:600,
    difficulty:"协作",
    deadline:"2 天",
    kind:"node_outsource",
    sourceOrderId:sourceOrder?.id||null,
    sourceOrgId:orgId,
    sourceNodeId:nodeId,
    externalStatus:"available"
  });
  node.status="outsourced";
  node.externalOrderId=orderId;
  save();
  closeOverlay();
  render();
}
```

- [ ] **Step 4: Simulate external acceptance**

For node orders only, render `模拟外部玩家承接`. Implement:

```js
function simulateExternalAcceptance(orderId){
  const order=state.marketOrders.find(item=>item.id===orderId);
  if(!order||order.kind!=="node_outsource")return;
  order.externalStatus="accepted";
  order.externalPartner="远山协作 MVO";
  order.completeOnDay=state.day+1;
  state.worldFeed.unshift({
    id:`feed-${Date.now()}`,
    type:"activity",
    title:"远山协作 MVO 承接了一项节点订单",
    detail:`《${order.name}》预计 1 天返回结果。`
  });
  save();
  renderWorld();
}
```

- [ ] **Step 5: Return the result to the source node**

Call `completeExternalNodeOrders()` inside `advanceWork()`:

```js
function completeExternalNodeOrders(){
  const completed=state.marketOrders.filter(order=>order.kind==="node_outsource"&&order.externalStatus==="accepted"&&order.completeOnDay<=state.day);
  for(const order of completed){
    const org=state.orgs.find(item=>item.id===order.sourceOrgId);
    const node=normalizeNodeStates(org).find(item=>item.id===order.sourceNodeId);
    node.status="completed";
    node.result=`由 ${order.externalPartner} 返回的节点成果`;
    state.worldFeed.unshift({
      id:`feed-${Date.now()}-${order.id}`,
      type:"activity",
      title:"节点协作已经完成",
      detail:`${order.externalPartner} 已把《${order.name}》的成果交回 ${org.name}。`
    });
  }
  state.marketOrders=state.marketOrders.filter(order=>!completed.includes(order));
}
```

- [ ] **Step 6: Verify the outsourcing loop**

Playwright scenario:

```text
open a running project
publish one node
switch to 世界
find the linked order
simulate external acceptance
advance one day
return to source MVO
assert the node is completed and names the external partner
```

- [ ] **Step 7: Run focused verification**

Run the static, script syntax, and browser commands from Task 1. Expected: PASS.

---

### Task 5: Final integration, visual review, and documentation

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`
- Modify: `mfu-demo/doc/MFU-v0.15到组织牧场-v0.2-迁移清单.md`
- Modify: `mfu-demo/doc/MFU-v0.2-迁移待决策-临时.md`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: complete world/workspace and node-outsourcing browser scenario.

- [ ] **Step 1: Update migration documentation**

Record:

```text
市场订单 → 世界 / 订单市场
已承接订单 → 我的工作台 / 订单板
进行中的项目 → MVO 节点运行图
节点外包 → 发布为世界订单并回流原 MVO
```

Remove the old description of one-click external progress.

- [ ] **Step 2: Extend the end-to-end browser flow**

Keep the existing scenario and add:

```text
accept a world order
assign it to an MVO
inspect node states
publish a node order
simulate external acceptance
receive the node result
finish the source order
accept delivery
invoice and receive payment
confirm organization growth
```

- [ ] **Step 3: Capture both main tabs**

Run:

```bash
playwright screenshot --browser chromium --viewport-size '1600,1000' \
  "file:///Users/chenruihua/Documents/Vaults/projects/ezagent-pr-1543/mfu-demo/MFU-MVO%E7%BB%84%E7%BB%87%E7%89%A7%E5%9C%BA-v0.2-%E5%8F%AF%E7%8E%A9%E5%8E%9F%E5%9E%8B.html" \
  "/tmp/mfu-workspace-final.png"
```

Use Playwright to switch to `世界` and capture `/tmp/mfu-world-final.png`.

Inspect:

- both top tabs remain visible;
- the current tab is obvious;
- no horizontal overflow at 1600×1000;
- market cards and world feed are readable;
- project node state colors are distinguishable;
- the fixed-height resource dock remains unchanged.

- [ ] **Step 4: Run final verification**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
awk '/<script>/{flag=1;next}/<\/script>/{flag=0}flag' mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html > /tmp/mfu-v02-script.js
node --check /tmp/mfu-v02-script.js
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/mvo-pasture-v02.browser.cjs
git diff --check
mix precommit
```

Expected:

- static contract PASS;
- script syntax PASS;
- browser flow PASS;
- diff check PASS;
- `mix precommit` PASS, or reports only the already-known unavailable repository dependencies.

- [ ] **Step 5: Request commit and push approval**

Show the final diff summary and verification results. Do not commit or push until ruihua explicitly approves.
