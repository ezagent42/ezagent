# MFU Distributed ERP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the standalone ERP panel and make orders, resources, organizations, finance, and pending decisions form one playable operating loop in the MFU incubator demo.

**Architecture:** Keep the single-file HTML prototype and one shared `state` object. The order board, resource dock, organization pasture, top status shortcuts, and pending-action sidebar render different views of the same order and resource records; state-changing actions write one event and rerender all affected views.

**Tech Stack:** Single-file HTML, CSS, browser JavaScript, localStorage, Node.js static-contract tests, Playwright browser-flow tests.

## Global Constraints

- Modify `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`; do not replace it with a separate app.
- Use the terminology of `mfu-demo/MFU-v0.15-可试玩原型.html`.
- The three primary operating areas are `订单板`, `资源栏`, and `孵化中的组织`.
- `资金` and `算力` are resource categories; top-bar values are shortcuts into those categories.
- Remove the standalone `孵化器 ERP` button, office ERP button, ERP modal, and ERP navigation.
- Keep `待处理` as the cross-area decision queue, not as a permanent record store.
- Preserve the MFU parchment-paper visual language and the v0.15 readable type scale.
- No new dependencies.
- After every HTML behavior change, extract the script block and run `node --check`.
- Run `mix precommit` at final verification; if repository dependencies remain unavailable, record that exact limitation.
- Ask ruihua before every commit or push.

---

### Task 1: Establish the shared operating records

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Produces: `normalizeState(rawState) -> state`
- Produces: `recordLedger(entry) -> void`
- Produces: `setOrderStatus(orderId, status) -> void`
- Produces: order fields `status`, `orgId`, `quotedAmount`, `invoiceStatus`, `paymentStatus`, `cost`, `income`
- Produces: resource fields `status`, `assignedOrgId`, `busyOrderId`, `acquisition`, `cost`, `expiresAt`
- Consumes: existing `state`, `save()`, `render()`, and localStorage key.

- [ ] **Step 1: Add failing static-contract assertions**

Add exact assertions:

```js
for (const token of [
  "normalizeState",
  "recordLedger",
  "setOrderStatus",
  "ledger:",
  "paymentStatus",
  "assignedOrgId"
]) assert.ok(html.includes(token), `missing shared operating record: ${token}`);
```

- [ ] **Step 2: Run the static test and confirm failure**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
```

Expected: FAIL on `normalizeState`.

- [ ] **Step 3: Extend the initial state and normalize saved games**

Use these values in every seeded order:

```js
{
  status: "unassigned",
  orgId: null,
  quotedAmount: 3200,
  invoiceStatus: "not_issued",
  paymentStatus: "not_due",
  cost: 0,
  income: 0
}
```

Add:

```js
function normalizeState(raw){
  const next = structuredClone(raw);
  next.ledger ||= [];
  next.tasks = next.tasks.map(order => ({
    status: "unassigned",
    orgId: null,
    quotedAmount: Number(String(order.reward || "0").replace(/[^\d]/g, "")),
    invoiceStatus: "not_issued",
    paymentStatus: "not_due",
    cost: 0,
    income: 0,
    ...order
  }));
  for(const resource of [...next.people, ...next.agents, ...next.assets]){
    resource.assignedOrgId ??= null;
    resource.busyOrderId ??= null;
    resource.acquisition ??= "自有";
    resource.cost ??= 0;
    resource.expiresAt ??= null;
  }
  return next;
}
function recordLedger(entry){
  state.ledger.unshift({id:`ledger-${Date.now()}`, day:state.day, ...entry});
}
function setOrderStatus(orderId,status){
  const order=state.tasks.find(item=>item.id===orderId);
  if(order) order.status=status;
}
```

Initialize loaded and seeded data through `normalizeState`.

- [ ] **Step 4: Verify syntax and static contract**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
sed -n '/<script>/,/<\/script>/p' mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html | sed '1d;$d' > /tmp/mfu-pasture-v02.js
node --check /tmp/mfu-pasture-v02.js
```

Expected: both commands PASS.

- [ ] **Step 5: Request approval and commit**

After ruihua approves:

```bash
git add mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html mfu-demo/test-mvo-pasture-v02.mjs mfu-demo/mvo-pasture-v02.browser.cjs
git commit -m "refactor(mfu): unify incubator operating records"
```

---

### Task 2: Turn the order board into the complete order lifecycle

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Consumes: normalized order records and `setOrderStatus`.
- Produces: `setOrderFilter(status) -> void`
- Produces: `openOrder(orderId) -> void`
- Produces: DOM IDs `#order-filters`, `#order-detail`.

- [ ] **Step 1: Write failing order-lifecycle assertions**

Add:

```js
for (const token of [
  "待确认", "待分配", "进行中", "待结算", "已完成",
  "setOrderFilter", "openOrder"
]) assert.ok(html.includes(token), `missing order lifecycle: ${token}`);
```

In the browser test, assert that selecting an order opens `#order-detail`.

- [ ] **Step 2: Run tests and confirm the first new assertion fails**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
```

Expected: FAIL on an order lifecycle token.

- [ ] **Step 3: Add status filters and lifecycle-aware cards**

Add `state.orderFilter = "unassigned"` and map:

```js
const ORDER_STATUS = {
  inquiry: "待确认",
  unassigned: "待分配",
  running: "进行中",
  settlement: "待结算",
  completed: "已完成",
  cancelled: "已取消"
};
function setOrderFilter(status){
  state.orderFilter=status;
  renderTodo();
}
```

Render compact filter buttons above the order list. Each card must show customer, amount, deadline/difficulty, order status, and responsible MVO when assigned.

- [ ] **Step 4: Add contextual order detail**

`openOrder(orderId)` must show:

```text
客户与联系人
需求与交付标准
报价与截止时间
负责的 MVO
执行 / 验收 / 开票 / 收款状态
沟通与变更记录
```

Actions must depend on status:

- `unassigned`: assign to an idle MVO or enter the organization workshop;
- `running`: open its MVO;
- `settlement`: show the delivery and account status;
- `completed`: view the immutable outcome and financial summary.

- [ ] **Step 5: Connect assignment and completion to order status**

Update existing behavior:

```js
order.status = "running";
order.orgId = org.id;
```

Keep the order in `state.tasks`; filters decide where it appears. Do not remove it from the array during assignment.

On delivery acceptance:

```js
order.status = "settlement";
order.invoiceStatus = "not_issued";
order.paymentStatus = "not_due";
```

Do not immediately add cash on delivery acceptance.

- [ ] **Step 6: Verify order lifecycle in Playwright**

Test this exact flow:

```text
待分配 → 选择订单 → 分配给空闲 MVO → 进行中
```

Run:

```bash
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/mvo-pasture-v02.browser.cjs
```

Expected: `MFU organization pasture v0.2 browser flow passed`.

- [ ] **Step 7: Request approval and commit**

After ruihua approves:

```bash
git add mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html mfu-demo/test-mvo-pasture-v02.mjs mfu-demo/mvo-pasture-v02.browser.cjs
git commit -m "feat(mfu): add playable order lifecycle"
```

---

### Task 3: Make funds and compute first-class resource categories

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Consumes: `state.cash`, `state.compute`, `state.ledger`, resource records.
- Produces: `openResourceTab("funds" | "compute") -> void`
- Produces: DOM selectors `[data-resource-tab="funds"]`, `[data-resource-tab="compute"]`, `#funds-resource-view`, `#compute-resource-view`.

- [ ] **Step 1: Write failing fund and compute assertions**

Add:

```js
for (const token of [
  'data-resource-tab="${id}"',
  "funds-resource-view",
  "compute-resource-view",
  "待收款",
  "待付款",
  "本周利润",
  "算力消耗记录"
]) assert.ok(html.includes(token), `missing resource finance/compute feature: ${token}`);
```

Add browser checks that `#cash-stat` and `#compute-stat` are clickable and open the appropriate resource tab.

- [ ] **Step 2: Run tests and confirm failure**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
```

Expected: FAIL on `funds-resource-view`.

- [ ] **Step 3: Replace the old resource tab set**

Render these five tabs from one array:

```js
[
  ["people", `👩‍🎓 人才 ${state.people.length}`],
  ["agents", `🤖 Agent ${state.agents.length}`],
  ["assets", `🧰 工具 / IP ${state.assets.length}`],
  ["compute", `⚡ 算力 ${state.compute}`],
  ["funds", `💰 资金 ¥${state.cash.toLocaleString()}`]
]
```

- [ ] **Step 4: Implement the funds resource view**

`#funds-resource-view` must show:

- available cash;
- receivables and payables;
- weekly income, cost, and profit;
- order account statuses;
- ledger records with source links;
- simplified invoice, tax, voucher, depreciation, and report sections.

Financial sections that are not interactive in v0.2 must be visibly labeled `记录` or `简报`, not disabled ERP forms.

- [ ] **Step 5: Implement the compute resource view**

`#compute-resource-view` must show:

- current available compute;
- compute occupied by each running MVO;
- recent compute consumption;
- expected release;
- an entry to obtain more compute.

- [ ] **Step 6: Turn top-bar values into shortcuts**

Give the existing top values IDs and click handlers:

```html
<button id="cash-stat" onclick="openResourceTab('funds')">...</button>
<button id="compute-stat" onclick="openResourceTab('compute')">...</button>
```

Both handlers must expand the dock, switch the tab, and scroll the resource dock into view.

- [ ] **Step 7: Verify both shortcut paths**

Run the static and browser tests. Expected browser behavior:

```text
click 可用资金 → resource dock expanded → 资金 selected
click 可用算力 → resource dock expanded → 算力 selected
```

- [ ] **Step 8: Request approval and commit**

After ruihua approves:

```bash
git add mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html mfu-demo/test-mvo-pasture-v02.mjs mfu-demo/mvo-pasture-v02.browser.cjs
git commit -m "feat(mfu): move finance and compute into resources"
```

---

### Task 4: Connect organization execution to resources, cost, and delivery

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Consumes: order `orgId`, resource `assignedOrgId`, ledger, existing organization details.
- Produces: `allResources() -> Array<Resource>`
- Produces: `assignResourcesToOrg(orgId, resourceIds) -> void`
- Produces: `releaseOrderResources(orderId) -> void`
- Produces: `calculateOrgEconomics(orgId) -> {income, cost, profit}`
- Produces: organization tabs `交付`, `经营记录`, `成长`.

- [ ] **Step 1: Add failing organization-economics assertions**

Assert:

```js
for (const token of [
  "assignResourcesToOrg",
  "releaseOrderResources",
  "calculateOrgEconomics",
  "交付",
  "经营记录",
  "成长"
]) assert.ok(html.includes(token), `missing organization operation: ${token}`);
```

- [ ] **Step 2: Run the static test and confirm failure**

Expected: FAIL on `assignResourcesToOrg`.

- [ ] **Step 3: Occupy resources on assignment**

When an order begins:

```js
function allResources(){
  return [...state.people,...state.agents,...state.assets];
}
function assignResourcesToOrg(orgId,resourceIds){
  for(const resource of allResources()){
    if(resourceIds.includes(resource.id)){
      resource.assignedOrgId=orgId;
    }
  }
}
```

The resource card must show the owning MVO and expected release.

- [ ] **Step 4: Add organization delivery and economics**

In organization details:

- `交付` shows current result, acceptance state, and rework history;
- `经营记录` shows order income, resource cost, compute cost, and profit;
- `成长` shows organization level, optimization points, experience, and certification;
- `资产` shows only resources currently attached to that organization.

Calculate:

```js
function calculateOrgEconomics(orgId){
  const orders=state.tasks.filter(order=>order.orgId===orgId);
  const income=orders.reduce((sum,order)=>sum+order.income,0);
  const cost=orders.reduce((sum,order)=>sum+order.cost,0);
  return {income,cost,profit:income-cost};
}
```

- [ ] **Step 5: Release only the current-order occupation**

Resources remain members of their MVO. When an order starts, set `busyOrderId` and `status="忙碌"`; after payment marks the order `completed`, clear only the busy state:

```js
function releaseOrderResources(orderId){
  for(const resource of allResources()){
    if(resource.busyOrderId===orderId){
      resource.busyOrderId=null;
      resource.status="空闲";
    }
  }
}
```

- [ ] **Step 6: Verify resource occupation and release**

Browser flow:

```text
assign order → open resource → resource shows MVO
finish delivery → issue invoice → receive payment
open resource → resource shows 空闲
```

- [ ] **Step 7: Request approval and commit**

After ruihua approves:

```bash
git add mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html mfu-demo/test-mvo-pasture-v02.mjs mfu-demo/mvo-pasture-v02.browser.cjs
git commit -m "feat(mfu): connect MVO execution to resources"
```

---

### Task 5: Complete settlement, growth, and pending decisions

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`

**Interfaces:**
- Consumes: order lifecycle, ledger, resource occupation, organization economics.
- Produces: `issueInvoice(orderId) -> void`
- Produces: `receivePayment(orderId) -> void`
- Produces: `completeSettlement(orderId) -> void`
- Produces: `addPendingAction(action) -> void`
- Produces: `resolvePendingAction(actionId, decision) -> void`

- [ ] **Step 1: Add failing closed-loop assertions**

Add:

```js
for (const token of [
  "issueInvoice",
  "receivePayment",
  "completeSettlement",
  "addPendingAction",
  "resolvePendingAction",
  "应收款逾期",
  "即将超预算",
  "资源冲突"
]) assert.ok(html.includes(token), `missing operating loop: ${token}`);
```

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL on `completeSettlement`.

- [ ] **Step 3: Add invoice and payment actions**

Use:

```js
function issueInvoice(orderId){
  const order=state.tasks.find(item=>item.id===orderId);
  if(!order || order.status!=="settlement") return;
  order.invoiceStatus="issued";
  order.paymentStatus="receivable";
  addPendingAction({type:"receivable",orderId,title:`《${order.name}》待收款`});
  save();
  render();
}
function receivePayment(orderId){
  const order=state.tasks.find(item=>item.id===orderId);
  if(!order || order.paymentStatus!=="receivable") return;
  completeSettlement(orderId);
}
```

Render `#issue-invoice` and `#receive-payment` only when their preconditions are true.

- [ ] **Step 4: Make settlement update every affected area**

Implement:

```js
function completeSettlement(orderId){
  const order=state.tasks.find(item=>item.id===orderId);
  const org=state.orgs.find(item=>item.id===order?.orgId);
  if(!order || !org) return;
  const amount=order.quotedAmount;
  order.paymentStatus="paid";
  order.status="completed";
  order.income=amount;
  state.cash+=amount;
  recordLedger({
    type:"income",
    amount,
    orderId:order.id,
    orgId:org.id,
    label:`《${order.name}》订单收入`
  });
  releaseOrderResources(order.id);
  org.status="idle";
  org.level+=1;
  org.task=null;
  org.progress=0;
  org.eta="";
  state.archive.push({
    orgId:org.id,
    task:order.name,
    client:order.client,
    quality:"A",
    income:amount
  });
  addPendingAction({
    type:"upgrade",
    orgId:org.id,
    title:`${org.name} 可以升级`,
    detail:"订单完成，获得一个组织优化点。"
  });
  save();
  render();
}
```

- [ ] **Step 5: Restrict the right sidebar to decisions**

Use `待处理` only for:

- new demand confirmation;
- quotation decision;
- delivery acceptance or rejection;
- customer change request;
- organization risk;
- insufficient compute;
- resource conflict;
- budget overrun;
- missing invoice or voucher;
- overdue receivable;
- expiring resource;
- organization upgrade.

Use these helpers so every action follows the same lifecycle:

```js
function addPendingAction(action){
  state.actions.push({id:`action-${Date.now()}`, ...action});
}
function resolvePendingAction(actionId,decision){
  const action=state.actions.find(item=>item.id===actionId);
  if(!action) return;
  state.logs.unshift(`W${state.day} · ${action.title}：${decision}`);
  state.actions=state.actions.filter(item=>item.id!==actionId);
  save();
  render();
}
```

Once resolved, remove the action and preserve its outcome in the related order, organization, resource, or ledger record.

- [ ] **Step 6: Add the end-to-end browser scenario**

The Playwright test must perform:

```text
select unassigned order
assign to idle MVO
advance work to review
accept delivery
open settlement order
issue invoice
receive payment
assert cash increased
assert order completed
assert organization idle and upgraded
assert attached resource is available but still belongs to the MVO
assert ledger contains order income
```

- [ ] **Step 7: Run all focused verification**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
sed -n '/<script>/,/<\/script>/p' mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html | sed '1d;$d' > /tmp/mfu-pasture-v02.js
node --check /tmp/mfu-pasture-v02.js
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/mvo-pasture-v02.browser.cjs
```

Expected: all PASS.

- [ ] **Step 8: Request approval and commit**

After ruihua approves:

```bash
git add mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html mfu-demo/test-mvo-pasture-v02.mjs mfu-demo/mvo-pasture-v02.browser.cjs
git commit -m "feat(mfu): complete incubator operating loop"
```

---

### Task 6: Remove standalone ERP and finish the handoff

**Files:**
- Modify: `mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html`
- Modify: `mfu-demo/test-mvo-pasture-v02.mjs`
- Modify: `mfu-demo/mvo-pasture-v02.browser.cjs`
- Modify: `mfu-demo/doc/MFU-v0.15到组织牧场-v0.2-迁移清单.md`
- Modify: `mfu-demo/doc/MFU-v0.2-迁移待决策-临时.md`

**Interfaces:**
- Consumes: all distributed operating features.
- Removes: `#open-erp`, `openErp`, `setErpTab`, `erpTabs`, `#erp-overlay`.
- Produces: final static and browser contracts for the distributed interface.

- [ ] **Step 1: Replace old ERP-positive tests with absence assertions**

Add:

```js
for (const removed of [
  'id="open-erp"',
  "孵化器 ERP",
  "openErp",
  "setErpTab",
  "erpTabs",
  'id="erp-overlay"'
]) assert.ok(!html.includes(removed), `standalone ERP remains: ${removed}`);
```

- [ ] **Step 2: Run the static test and confirm it fails**

Expected: FAIL because `#open-erp` still exists.

- [ ] **Step 3: Remove all standalone ERP UI and code**

Remove:

- top-bar ERP button;
- office `打开 ERP` button;
- ERP modal markup;
- ERP navigation data;
- ERP render and event functions;
- browser tests that open ERP.

Do not remove the data or behavior already migrated into the three main areas.

- [ ] **Step 4: Update migration documentation**

Mark each former ERP area as migrated:

```text
订单 → 订单板
组织 / 项目 → 孵化中的组织
资产 / 采购 → 资源栏
财务 / 算力 → 资源栏
决策与异常 → 待处理
```

Keep undecided mechanics in the temporary decision document; do not silently implement them.

- [ ] **Step 5: Perform visual review**

Capture at 1600×1000 and inspect:

```bash
playwright screenshot --browser chromium --viewport-size '1600,1000' \
  "file:///Users/chenruihua/Documents/Vaults/projects/ezagent-pr-1543/mfu-demo/MFU-MVO%E7%BB%84%E7%BB%87%E7%89%A7%E5%9C%BA-v0.2-%E5%8F%AF%E7%8E%A9%E5%8E%9F%E5%9E%8B.html" \
  "/tmp/mfu-distributed-erp.png"
```

Confirm:

- no text below 9.5px;
- no overlap in the order sidebar;
- five resource tabs fit at 1600px;
- organization cards remain readable;
- no standalone ERP entry remains;
- keyboard focus remains visible.

- [ ] **Step 6: Run final verification**

Run:

```bash
node mfu-demo/test-mvo-pasture-v02.mjs
sed -n '/<script>/,/<\/script>/p' mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html | sed '1d;$d' > /tmp/mfu-pasture-v02.js
node --check /tmp/mfu-pasture-v02.js
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/mvo-pasture-v02.browser.cjs
git diff --check
mix precommit
```

Expected:

- static contract PASS;
- script syntax PASS;
- browser flow PASS;
- `git diff --check` PASS;
- `mix precommit` PASS, or a recorded dependency-unavailable result matching the worktree environment.

- [ ] **Step 7: Request approval and commit**

After ruihua approves:

```bash
git add mfu-demo/MFU-MVO组织牧场-v0.2-可玩原型.html mfu-demo/test-mvo-pasture-v02.mjs mfu-demo/mvo-pasture-v02.browser.cjs mfu-demo/doc/MFU-v0.15到组织牧场-v0.2-迁移清单.md mfu-demo/doc/MFU-v0.2-迁移待决策-临时.md
git commit -m "refactor(mfu): distribute ERP across the game workspace"
```
