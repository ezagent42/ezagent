# MFU Skill Trees — Living Document

> **状态**: Living · 与 `MFU-v0.14-可试玩原型.html` 同步
> **最后更新**: 2026-07-24
> **用途**: 枚举全部 skill tree 节点、scope、解锁条件、渲染逻辑，作为设计与实施的单一事实源。

---

## 1. 架构总览

MFU 有两棵成长树，共享同一套渲染引擎（`renderRadialTree(scope)` + `nodeAngle(n, scope)`），通过 `scope` 字段区分：

| Scope | 树名 | 节点数 | 访问路径 | 视角 |
|---|---|---|---|---|
| `'company'` | 🌳 公司成长树 | 15 | ERP → 成长树 tab | 这家公司能做什么 |
| `'personal'` | 🌱 个人成长树 | 7 | 主理人档案 → 内嵌 | 这个人能做什么（跨公司保留） |

### 渲染参数

| 参数 | 公司树 | 个人树 |
|---|---|---|
| SVG viewBox | `0 0 660 540` | `0 0 580 320` |
| 中心点 | `(330, 280)` | `(290, 150)` |
| Tier 半径 | `0:0, 1:78, 2:150, 2.5:220, 3:285, 3.5:350` | `0:0, 1:48, 2:95, 2.5:138, 3:180, 3.5:225` |
| 节点圆半径 | tier 0 = 20, 其他 = 16 | 统一 = 12 |
| 连线 | 正交路径（水平+垂直）+ `stroke-linejoin:round` | 同左 |
| 平移 | `#treePanWrap` + `initTreePan('treePanWrap')` | `#personalTreePanWrap` + `initTreePan('personalTreePanWrap')` |

### 连线逻辑

连线从父节点（`deps[]`）指向子节点，使用正交路径：

```
M parentX parentY  →  L parentX midY  →  L childX midY  →  L childX childY
```

`midY = parentY + (childY - parentY) * 0.55`（偏向父节点一端）。

CSS: `stroke-width:3; stroke-linejoin:round; stroke-linecap:round`。
状态 class：`unlocked`（子节点已解锁 → 实线 teal）、`available`（仅父节点解锁 → 虚线 gold）、默认（虚线 gray）。

---

## 2. 公司成长树（scope: `'company'`）

### N-00 · 公司注册

| 字段 | 值 |
|---|---|
| Tier | 0（根） |
| Verb | 注册 |
| Icon | 🏢 |
| Group | base |
| Deps | — |
| Cond | 进入游戏即解锁 |
| condFn | `() => S.started` |

### N-01 · 设计专精

| 字段 | 值 |
|---|---|
| Tier | 1 |
| Verb | 调教 |
| Icon | 🎨 |
| Group | specialty |
| Deps | N-00 |
| Cond | 设计练习单 ≥ 5 |
| condFn | `() => S.credits.design >= 5` |

### N-02 · 文案专精

| 字段 | 值 |
|---|---|
| Tier | 1 |
| Verb | 编写 |
| Icon | ✍️ |
| Group | specialty |
| Deps | N-00 |
| Cond | 文案练习单 ≥ 5 |
| condFn | `() => S.credits.copy >= 5` |

### N-03 · 增长专精

| 字段 | 值 |
|---|---|
| Tier | 1 |
| Verb | 投放 |
| Icon | 📈 |
| Group | specialty |
| Deps | N-00 |
| Cond | 增长练习单 ≥ 5 |
| condFn | `() => S.credits.growth >= 5` |

### N-04 · 设计提案

| 字段 | 值 |
|---|---|
| Tier | 2 |
| Verb | 提案 |
| Icon | 📋 |
| Group | deepen |
| Deps | N-01 |
| Cond | 设计专精 + 真单 ≥ 3 |
| condFn | `() => {const n = S.treeNodes['N-01']; return n && n.unlocked && S.lines.design >= 3;}` |

### N-05 · 品牌模板

| 字段 | 值 |
|---|---|
| Tier | 2 |
| Verb | 复用 |
| Icon | 📄 |
| Group | deepen |
| Deps | N-02 |
| Cond | 文案专精 + 真单 ≥ 3 |
| condFn | `() => {const n = S.treeNodes['N-02']; return n && n.unlocked && S.lines.copy >= 3;}` |

### N-06 · A/B实验

| 字段 | 值 |
|---|---|
| Tier | 2 |
| Verb | 实验 |
| Icon | 🧪 |
| Group | deepen |
| Deps | N-03 |
| Cond | 增长专精 + 真单 ≥ 3 |
| condFn | `() => {const n = S.treeNodes['N-03']; return n && n.unlocked && S.lines.growth >= 3;}` |

### N-07 · 白银认证

| 字段 | 值 |
|---|---|
| Tier | 2.5（资质门） |
| Verb | 入会 |
| Icon | 🥈 |
| Group | gate |
| Deps | —（无依赖，独立解锁） |
| Cond | 声望 ≥ 30 + 信用 ≥ 70 |
| condFn | `() => S.rep >= 30 && S.cred >= 70` |

### N-08 · 联合竞标

| 字段 | 值 |
|---|---|
| Tier | 3 |
| Verb | 联合 |
| Icon | 🤝 |
| Group | cross |
| Deps | N-07 |
| Cond | 白银 + ≥ 2 条 T1 线 |
| condFn | `() => {const t1 = ['N-01','N-02','N-03']; const n7 = S.treeNodes['N-07']; return n7 && n7.unlocked && t1.filter(id => S.treeNodes[id] && S.treeNodes[id].unlocked).length >= 2;}` |

### N-09 · 资产出租

| 字段 | 值 |
|---|---|
| Tier | 3 |
| Verb | 出租 |
| Icon | 🏷️ |
| Group | cross |
| Deps | N-07 |
| Cond | 白银 + 任一 T2 |
| condFn | `() => {const n7 = S.treeNodes['N-07']; if (!n7 || !n7.unlocked) return false; return ['N-04','N-05','N-06'].some(id => S.treeNodes[id] && S.treeNodes[id].unlocked);}` |

### N-10 · 公开评审

| 字段 | 值 |
|---|---|
| Tier | 3 |
| Verb | 评审 |
| Icon | 🔍 |
| Group | cross |
| Deps | N-07 |
| Cond | 白银 + 作品集 ≥ 10 |
| condFn | `() => {const n7 = S.treeNodes['N-07']; return n7 && n7.unlocked && S.profile.portfolio >= 10;}` |

### N-11 · 黄金认证

| 字段 | 值 |
|---|---|
| Tier | 3.5（角色） |
| Verb | 入驻 |
| Icon | 🥇 |
| Group | role |
| Deps | N-07 |
| Cond | 声望 ≥ 85 + 均分 ≥ 74 |
| condFn | `() => S.rank >= 2 && S.realN >= 2 && (S.realQ.length ? S.realQ.reduce((a,b) => a+b, 0) / S.realQ.length : 0) >= 74` |

### N-12 · 教练认证

| 字段 | 值 |
|---|---|
| Tier | 3.5（角色） |
| Verb | 带教 |
| Icon | 🎓 |
| Group | role |
| Deps | N-07 |
| Cond | 联机版：带队 ≥ 5 家 · 单机版待定 |
| condFn | `() => false`（联机版功能，单机版永久锁定） |

### N-13 · 孵化认证

| 字段 | 值 |
|---|---|
| Tier | 3.5（角色） |
| Verb | 孵化 |
| Icon | 🏭 |
| Group | role |
| Deps | N-07 |
| Cond | 外部资质（孵化平台授予） |
| condFn | `() => false`（外部授予，游戏内不可自行解锁） |

### N-14 · 平台运营

| 字段 | 值 |
|---|---|
| Tier | 3.5（角色） |
| Verb | 治理 |
| Icon | 🦄 |
| Group | ezagent |
| Deps | N-07 |
| Cond | ezagent 团队内部资质 |
| condFn | `() => false`（ezagent 团队内部，玩家不可解锁） |

---

## 3. 个人成长树（scope: `'personal'`）

> 个人树不受公司破产影响。节点状态跟随主理人档案跨公司保留。

### P-00 · 跨组织从业

| 字段 | 值 |
|---|---|
| Tier | 0（根） |
| Verb | 连接 |
| Icon | 🔗 |
| Group | base |
| Deps | — |
| Cond | 完成打工 ≥ 1 次 |
| condFn | `() => S.profile.net >= 1` |

### P-01 · 作品积累

| 字段 | 值 |
|---|---|
| Tier | 1 |
| Verb | 归档 |
| Icon | 🗂️ |
| Group | specialty |
| Deps | P-00 |
| Cond | 作品集 ≥ 3 |
| condFn | `() => S.profile.portfolio >= 3` |

### P-02 · 人脉经营

| 字段 | 值 |
|---|---|
| Tier | 1 |
| Verb | 拓展 |
| Icon | 🤝 |
| Group | specialty |
| Deps | P-00 |
| Cond | 人脉 ≥ 3 |
| condFn | `() => S.profile.net >= 3` |

### P-03 · 复盘沉淀

| 字段 | 值 |
|---|---|
| Tier | 2 |
| Verb | 反思 |
| Icon | 📝 |
| Group | deepen |
| Deps | P-01 |
| Cond | 复盘素材 ≥ 5 |
| condFn | `() => S.reviews.length >= 5` |

### P-04 · 判断力认证

| 字段 | 值 |
|---|---|
| Tier | 2.5（资质门） |
| Verb | 认证 |
| Icon | 🎯 |
| Group | gate |
| Deps | P-02 |
| Cond | 判断力 ≥ 60%（至少 5 次判断） |
| condFn | `() => {const jt = S.profile.judgeT; return jt >= 5 && S.profile.judgeG / jt >= 0.6;}` |

### P-05 · 孵化器背书

| 字段 | 值 |
|---|---|
| Tier | 3 |
| Verb | 背书 |
| Icon | 🏭 |
| Group | cross |
| Deps | P-04 |
| Cond | 加入孵化器预备营 |
| condFn | `() => S.guilds.incu === true` |

### P-06 · 创业导师

| 字段 | 值 |
|---|---|
| Tier | 3.5（角色） |
| Verb | 带教 |
| Icon | 🎓 |
| Group | role |
| Deps | P-05 |
| Cond | 黄金认证（声望 ≥ 85） |
| condFn | `() => S.rank >= 2` |

---

## 4. 节点状态机

每个节点在 `S.treeNodes[id]` 中存储 `{unlocked: boolean}`。

### 初始化

```javascript
function initTreeNodes(){
  TREE_NODES.forEach(n => {S.treeNodes[n.id] = {unlocked: n.condFn()};});
}
```

在 `$('startBtn').onclick` 中调用。

### 周常检查

```javascript
function checkTreeNodes(){
  let newly = [];
  TREE_NODES.forEach(n => {
    if (!S.treeNodes[n.id].unlocked && n.condFn()) {
      S.treeNodes[n.id].unlocked = true;
      newly.push(n);
    }
  });
  return newly;
}
```

在 `tick()`（每周结算）中调用。新解锁的节点会记录到日志：`"🌳 科技树解锁 N 个节点：🎨 设计专精 · ..."`

### 三种渲染状态

| 状态 | CSS class | 条件 | 视觉效果 |
|---|---|---|---|
| unlocked | `.tnode.unlocked` | `S.treeNodes[id].unlocked === true` | cream 填充 + teal 描边 |
| available | `.tnode.available` | `!unlocked && condFn()` | 金色虚线描边 + 脉冲动画 |
| locked | `.tnode.locked` | 以上皆否 | 灰色填充 + 灰色描边 · `cursor:default` |

连线对应三种状态：`.tline.unlocked`（teal）、`.tline.available`（金色虚线）、默认（灰色虚线）。

---

## 5. 渲染管线

```
renderRadialTree(scope)
  ├── checkTreeNodes()                  // 刷新解锁状态
  ├── filter TREE_NODES by scope        // 选出当前树的节点
  ├── 背景环 [0, 1, 2, 2.5, 3, 3.5]   // <circle class="tree-ring">
  ├── 连线 (n.deps → parent)            // <path> 正交路径 + stroke-linejoin:round
  │   └── nodeAngle(n, scope) → 角度   // 按 scope 过滤同 tier 节点后均分
  └── 节点                              // <circle class="tnode"> + <text>
      └── onclick → openNodeDetail(id)  // 弹窗：图标/名称/verb/等级条/条件/依赖
```

### 关键函数签名

```javascript
function renderRadialTree(scope)        // scope = 'company' | 'personal'，默认 'company'
function nodeAngle(n, scope)            // 返回节点在环上的弧度角
function initTreePan(wrapId)            // 鼠标/触摸拖拽平移，wrapId 默认 'treePanWrap'
function openNodeDetail(nid)            // 节点详情弹窗（搜索全部 TREE_NODES，不限 scope）
```

---

## 6. 数据源映射

公司树的 `condFn` 读取以下 `S` 字段：

| S 字段 | 类型 | 被哪些节点使用 |
|---|---|---|
| `S.started` | bool | N-00 |
| `S.credits.design` | number | N-01 |
| `S.credits.copy` | number | N-02 |
| `S.credits.growth` | number | N-03 |
| `S.lines.design` | number | N-04 |
| `S.lines.copy` | number | N-05 |
| `S.lines.growth` | number | N-06 |
| `S.rep` | number | N-07, N-11 |
| `S.cred` | number | N-07 |
| `S.treeNodes['N-01'..'N-07']` | object | N-04, N-05, N-06, N-08, N-09, N-10 |
| `S.profile.portfolio` | number | N-10 |
| `S.rank` | number | N-11 |
| `S.realN` | number | N-11 |
| `S.realQ` | array | N-11 |

个人树的 `condFn` 读取以下 `S.profile` 字段：

| S 字段 | 类型 | 被哪些节点使用 |
|---|---|---|
| `S.profile.net` | number | P-00, P-02 |
| `S.profile.portfolio` | number | P-01 |
| `S.reviews.length` | number | P-03 |
| `S.profile.judgeT` | number | P-04 |
| `S.profile.judgeG` | number | P-04 |
| `S.guilds.incu` | bool | P-05 |
| `S.rank` | number | P-06 |

---

## 7. 扩展指南

### 新增一个公司节点

在 `TREE_NODES` 数组中，`N-14` 之后、`// ---- 个人成长树节点 ----` 注释之前插入：

```javascript
{id:'N-15',tier:4,name:'新节点名称',verb:'动作',icon:'🆕',group:'newgroup',scope:'company',deps:['N-11'],
 cond:'条件描述',condFn:()=>/* your condition */,level:{cur:0,max:1}},
```

### 新增一个个人节点

在 `P-06` 之后、`];` 之前插入（格式同上，`scope:'personal'`, `deps` 引用 P-xx 节点）。

### 新增 tier

1. 在 `renderRadialTree` 中扩展 `radii` 映射（两个 scope 都需要对应半径）
2. 在背景环渲染的 `[0,1,2,2.5,3,3.5]` 数组中添加新 tier
3. 确保新 tier 的半径不超过 viewBox 范围

---

## 8. 变更记录

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-07-24 | v0.14 | 初始版本：15 个公司节点 + 7 个个人节点，scope 分离，正交连线，living doc 创建 |
