# CLAUDE.md — ezagent（核心引擎）

EZAgent 核心引擎，实现基于 CRDT 的协作协议。人类与 AI Agent 作为平等参与者（Entity-Agnostic 设计）。License: Apache 2.0。

## 技术栈

- **Rust** — 核心引擎实现
  - `yrs` (Yjs CRDT) — 数据同步（LWW / YATA 排序）
  - `zenoh` — P2P 网络通信（LAN scouting + Relay fallback）
  - `rocksdb` — 本地持久化存储
  - `ed25519-dalek` — 签名与身份验证
  - `PyO3` — Python 绑定（唯一对外接口）
  - `clap` — CLI 命令行解析
  - `thiserror` — 领域错误类型
  - `tokio` — 异步运行时
- **Python** — SDK + HTTP API 层
  - `FastAPI` — HTTP/WebSocket API 服务
  - `uvicorn` — ASGI 服务器
  - PyO3 绑定通过 `ezagent._native` 模块暴露

## 架构

三层分形架构：

```
Layer 2 (Extensions):  17 可选扩展（EXT-01 ~ EXT-17），按 Room 激活
Layer 1 (Built-in):    Identity → Room → Timeline → Message
Layer 0 (Engine):      Datatype Registry, Hook Pipeline, Annotation Store, Index Builder
```

Engine 内部四大支柱：

| 组件 | 职责 | 详见 |
|------|------|------|
| **Datatype Registry** | 类型声明、依赖解析、扩展加载 | `docs/specs/bus-spec.md §1` |
| **Hook Pipeline** | 三阶段生命周期回调 | `docs/specs/bus-spec.md §2` |
| **Annotation Store** | `{type}:{entity_id}` 键值对，附着于 Timeline Ref | `docs/specs/bus-spec.md §3` |
| **Index Builder** | 操作映射、自动/按需刷新 | `docs/specs/bus-spec.md §4` |

### 数据模型（双层分离）

- **Layer 1 — Timeline Index:** `Y.Array<Y.Map>` 按月分片（shard_id），YATA 全局排序
- **Layer 2 — Content Objects:** 不可变（hash 寻址）或可变/协作（UUID 寻址）CRDT 文档

### Key Space 结构

```
ezagent/
├── entity/@{entity_id}/
│   ├── identity/pubkey              # Ed25519 公钥（blob）
│   └── ext/{ext_id}/{state|updates}
├── room/{room_id}/
│   ├── config/{state|updates}       # 房间配置（crdt_map）
│   ├── index/{shard_id}/{state|updates}  # 月度 Timeline 分片
│   ├── content/{hash|uuid}/{state|updates}
│   ├── blob/{hash}
│   └── ext/{ext_id}/{state|updates}
└── relay/{relay_domain}/            # 本地运维数据，不参与 CRDT 同步
```

**规则：** CRDT 文档必须成对存储 `state`（完整快照）+ `updates`（增量更新）。

### Identity 模型

- Entity ID 格式：`@{local_part}:{relay_domain}`（身份命名空间，非网络地址）
- 首次注册需 TLS 连接 Public Relay（一次性），之后离线可用
- Ed25519 密钥对本地存储

## Hook Pipeline 语义

三阶段执行，优先级排序：**Built-in 0–9 → Extension 10–99 → Socialware 100+**

| 阶段 | 可写 | 错误处理 | 用途 |
|------|------|----------|------|
| `pre_send` | 可修改当前数据 | **拒绝 = 阻止 CRDT 写入** | 权限检查、校验、字段注入 |
| `after_write` | 只读当前，可写其他 DataType | 失败不回滚（CRDT 已应用），链继续 | 触发副作用、级联更新 |
| `after_read` | 完全只读 | 失败返回原始数据（非错误） | UI 增强、附加字段 |

**关键：** `pre_send` 最后一步是 `identity.sign` hook（特殊最高优先级）。

## Built-in 四实体

| 实体 | 存储类型 | Writer Rule | 要点 |
|------|----------|-------------|------|
| **Identity** | blob | owner only | Ed25519 公钥，首次注册走 Relay TLS |
| **Room** | crdt_map | power_level 驱动 | membership_policy: "invite" / "open"，`enabled_extensions` 控制扩展激活 |
| **Timeline** | crdt_array | signer 写入 | 月度分片，Ref 结构含 `ext.*` 注解命名空间 |
| **Message** | 混合 | 按内容类型 | 不可变(sha256) / 可变(uuid) / 协作(uuid+ACL) |

## 扩展系统

- 17 个扩展（EXT-01 ~ EXT-17），详见 `docs/specs/extensions-spec.md`
- 动态加载：`.so` / `.dylib` 从 `~/.ezagent/extensions/{name}/`
- 按 Room 激活：`enabled_extensions` 配置，激活前检查依赖
- **禁用 ≠ 删除**：扩展禁用后 hook 停止执行，但已写入的 `ext.*` 数据保留

关键扩展依赖链：

```
message → mutable(EXT-01) → collaborative(EXT-02)
timeline → reply-to(EXT-04) → cross-room(EXT-05) / threads(EXT-11)
channels(EXT-06) + reply-to + command(EXT-15) → runtime(EXT-17, Socialware 入口)
```

## 同步协议

- **Initial Sync:** State Vector 查询 → 全量或差量更新
- **Live Sync:** Pub/Sub 到 `{key_pattern}/updates`，Signed Envelope 封装
- **Signed Envelope 格式：** version(1B) + signer_id + doc_id + timestamp(8B) + payload + signature(64B)
- **时间容差：** ±5 分钟
- **Zenoh QoS:** Reliable, priority=Data, congestion_control=Block
- **P2P 恢复：** Peer 注册为 Zenoh Queryable，支持离线重连后数据恢复

## Crate 结构

| Crate | 路径 | 说明 |
|-------|------|------|
| `ezagent-protocol` | `crates/ezagent-protocol/` | 协议原语（EntityId, Crypto, Envelope, KeyPattern, Sync） |
| `ezagent-backend` | `crates/ezagent-backend/` | 存储后端（Yrs CRDT, Zenoh P2P, RocksDB 持久化） |
| `ezagent-engine` | `crates/ezagent-engine/` | 核心引擎（Engine, Operations, EventStream, Hook Pipeline） |
| `ezagent-ext-api` | `crates/ezagent-ext-api/` | 扩展 API trait + 动态加载 |
| `ezagent-ext-*` | `crates/ezagent-ext-*/` | 17 个扩展实现（EXT-01 ~ EXT-17） |
| `ezagent-cli` | `crates/ezagent-cli/` | CLI 工具（`ezagent` 命令） |
| `ezagent-py` | `crates/ezagent-py/` | PyO3 绑定（PyEngine, PyEventReceiver） |

## CLI 命令

二进制名称：`ezagent`，配置目录：`~/.ezagent/`

| 命令 | 说明 | 关键参数 |
|------|------|----------|
| `ezagent init` | 初始化 identity | `--entity-id`, `--relay` |
| `ezagent identity whoami` | 显示当前身份 | |
| `ezagent room create` | 创建房间 | `--name` |
| `ezagent room show <id>` | 查看房间详情 | |
| `ezagent room invite <room> <entity>` | 邀请成员 | |
| `ezagent rooms list` | 列出所有房间 | `--json` |
| `ezagent send <room>` | 发送消息 | `--body`, `--format` |
| `ezagent messages <room>` | 查看消息 | `--limit`, `--json` |
| `ezagent events` | 监听事件流 | `--room`, `--json` |
| `ezagent status` | 引擎状态 | |
| `ezagent start` | 启动 HTTP 服务 | `--bind`, `--port` |
| `ezagent open <uri>` | URI 导航 | `ezagent://authority/r/{room_id}` |

退出码：0 成功，1 通用错误，2 INVALID_URI，3 RESOURCE_NOT_FOUND

## HTTP API

FastAPI 服务（`python/ezagent/server.py`），通过 `ezagent start` 或 `uvicorn ezagent.server:app` 启动。

### Bus API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/status` | 引擎状态 |
| GET | `/api/identity` | 当前身份（需初始化，否则 401） |
| GET | `/api/identity/{entity_id}/pubkey` | 获取公钥 |
| POST | `/api/rooms` | 创建房间 |
| GET | `/api/rooms` | 列出房间 |
| GET | `/api/rooms/{room_id}` | 房间详情 |
| PATCH | `/api/rooms/{room_id}` | 更新房间配置 |
| POST | `/api/rooms/{room_id}/invite` | 邀请成员 |
| POST | `/api/rooms/{room_id}/join` | 加入房间 |
| POST | `/api/rooms/{room_id}/leave` | 离开房间 |
| GET | `/api/rooms/{room_id}/members` | 成员列表 |
| POST | `/api/rooms/{room_id}/messages` | 发送消息 |
| GET | `/api/rooms/{room_id}/messages` | 消息列表（支持 `?limit=N`） |
| GET | `/api/rooms/{room_id}/messages/{ref_id}` | 单条消息 |
| DELETE | `/api/rooms/{room_id}/messages/{ref_id}` | 删除消息 |
| POST | `/api/rooms/{room_id}/annotations` | 添加注解 |
| GET | `/api/rooms/{room_id}/annotations` | 注解列表 |
| DELETE | `/api/rooms/{room_id}/annotations/{key}` | 删除注解 |
| WS | `/ws` | 事件流 WebSocket（支持 `?room=` 过滤） |

扩展端点（24 个）均返回 501 Not Implemented，待扩展实现后启用。

### PyO3 线程模型

`PyEngine` 和 `PyEventReceiver` 均标记 `#[pyclass(unsendable)]`（Engine 含 `libloading` 原始指针）。HTTP 服务使用 `threading.local()` + 版本计数器确保线程亲和性。测试中 `TestClient` 需使用上下文管理器（`with TestClient(app) as client:`）以固定 portal 线程。

## 开发指南

### Rust 规范

- `cargo fmt` + `cargo clippy` 保持代码风格
- 错误处理用 `thiserror` 定义领域错误，**禁止 `unwrap()` / `expect()`**
- 公开 API 必须有 `///` 文档注释
- 异步运行时用 `tokio`

### Python 绑定

- PyO3 绑定代码放独立模块
- Python API 风格遵循 `docs/specs/py-spec.md`
- 包管理用 `uv`（**禁止 `pip`**）
- 类型注解用 Python 3.10+ 语法
- Hook 回调 GIL 管理：Rust hook 释放 GIL → Python 100+ hook → sign

### 五种存储类型

实现 Datatype 时必须正确选择：

| 类型 | CRDT 语义 | 典型用途 |
|------|-----------|----------|
| `crdt_map` | Last-Writer-Wins | Room config, Profile |
| `crdt_array` | YATA 排序 | Timeline Index |
| `crdt_text` | YATA 字符级 | 协作文档 |
| `blob` | 不可变，hash 寻址 | 公钥、媒体附件 |
| `ephemeral` | 无持久化 | Presence、Awareness |

## 测试

### 运行

- 单元测试与源码同文件（`#[cfg(test)]` 模块）
- 集成测试放在 `tests/` 目录
- Fixture 数据参考 `docs/plan/fixtures.md`

#### 两级测试策略

```bash
# 确定性测试（默认，CI 安全）
cargo test --workspace        # Rust 确定性测试（全 workspace）
uv run pytest                 # Python 测试（PyO3 桥接 + HTTP API + WebSocket）

# 单独运行 CLI 测试
cargo test -p ezagent-cli

# 单独运行 Python HTTP 测试
uv run pytest tests/python/test_http_api.py -v

# 构建 PyO3 native 模块（修改 Rust 代码后需重新构建）
uv run maturin develop -p ezagent-py

# 环境依赖测试（需要本地基础设施）
cargo test -- --ignored       # 运行所有被 #[ignore] 标记的测试
```

**环境依赖测试清单：**

| 测试 | 依赖 | 启动命令 |
|------|------|----------|
| `tc_0_p2p_001_lan_scouting` | UDP multicast (224.0.0.224:7446) | 需要支持 multicast 的网络环境 |
| `tc_0_p2p_003_relay_fallback` | `zenohd` router | `zenohd -l tcp/0.0.0.0:7447 &` |
| `end_to_end_extension_loading` | `cargo build -p ezagent-ext-test-dummy` | `cargo test -p ezagent-engine --test extension_loader_tests -- --ignored` |

**编写环境依赖测试的规范：**
- 使用 `#[ignore = "reason — run: command"]` 标注
- 显式运行时（`--ignored`），环境不满足必须 **hard-fail**（`panic!` + 清晰错误信息），禁止 graceful skip 假阳性
- 在此表格中登记新增的环境依赖测试

### 测试用例编号

```
TC-{phase}-{area}-{number}
示例: TC-1-HOOK-003  (Phase 1, Hook 领域, 第 3 个用例)
```

### Fixture 体系

详见 `docs/plan/fixtures.md`。JSON 格式，目录镜像 Key Space 结构。

**测试实体：**
- 人类: `@alice`, `@bob`（同 Relay），`@carol`（跨 Relay）
- AI Agent: `@code-reviewer`, `@translator`
- 对抗: `@mallory`（伪造签名、篡改内容）
- 管理: `@admin`

**测试房间：**
- `R-alpha` — 完整功能（10 扩展）
- `R-beta` — 基础扩展（4 扩展）
- `R-gamma` — 开放策略（12 扩展）
- `R-empty` — 纯 Bus 测试（0 扩展）
- `R-minimal` — 同步测试（0 扩展）

**错误 Fixture：** ERR-SIGN-001（伪造签名）、ERR-MSG-002（篡改内容）、ERR-MSG-003（作者不匹配）、ERR-SIGN-003（时间戳偏移）

### 分阶段实施

| Phase | 范围 | Gate |
|-------|------|------|
| **0** | yrs + Zenoh + PyO3 验证 | 11 TC pass, Fixture 加载 |
| **1** | Engine + Backend + Built-in | ~120 TC, 100% spec 覆盖 |
| **2** | 15 扩展 (EXT-01 ~ -15) | ~100 TC, 完整 Extension API |
| **2.5** | PyO3 绑定 + 自动生成 API | py-spec §1-7 完成 |
| **3** | CLI + HTTP API | 77 TC — **Phase 4 实现: 82 Python TC + 41 CLI unit TC + 14 CLI integration TC** |
| **4** | Chat React UI + Desktop 打包 | 69 TC |
| **5** | Socialware 四原语 + 示例 | 84 TC |

**Gate 标准：** 所有 TC pass + Fixture 验证 + Spec 可追溯 100% + 无 P0/P1 bug。

## 合规级别

| Level | 包含 | 用途 |
|-------|------|------|
| 0 Core | Built-in only | 最小可用 |
| 1 Standard | + EXT-01,-03,-04,-08,-09,-10,-16 | 标准聊天 |
| 2 Advanced | Level 1 + EXT-02,-05,-06,-07,-13,-14,-15 | 完整协作 |
| 3 Socialware-Ready | Level 2 + EXT-17 | 组织级协作 |

## Commit scope

在此目录下的变更使用 `ezagent` 作为 commit scope：

```
feat(ezagent): add hook pipeline executor
fix(ezagent): handle CRDT merge conflict in timeline sharding
```
