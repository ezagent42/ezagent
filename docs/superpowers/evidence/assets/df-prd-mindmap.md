# df-prd 产品开发工作台 (mindmap)
## 价值: 开发/产品/运营三合一·全链路追踪
### 模块: 节点数据模型
#### 功能: stage/owner/status/artifacts/metrics
#### 功能: per-node CapBAC (admin+节点owner)
##### 开发✓: CapBAC-deny e2e 真dispatch
### 模块: external_mirror (Miro)
#### 功能: 出站增量同步 (复用同板)
##### 开发✓: 改名=delete+create 真Miro e2e
#### 功能: 入站轮询 (非破坏性)
##### 开发✓: 人加Miro→detect→dispatch回ezagent
##### 运营指标: 同步延迟 / 周闭环数
