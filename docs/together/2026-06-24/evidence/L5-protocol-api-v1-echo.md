# L5 — protocol-api /v1 端到端证据 (echo flavor)

**日期:** 2026-06-24 · **server:** 活 `:10042`(zyli-fullflow-validation-0624)

## 准备
- echo agent `entity://system/agent/test-echo-1`(L2 创建)
- protocol_api key 铸入活 DB(`--no-start` 最小启 Repo+Bcrypt,不启全 app):
  `pk_echotest_echopass` → target_agent=test-echo-1, entity=admin, ws=system

## 探针(挂载确认)
```
POST /v1/chat/completions (假 key) → 400 {"error":{"message":":invalid_token","type":"api_error"}}
router.ex:186  forward "/v1/chat/completions", EzagentPluginProtocolApi.OpenaiChatPlug
```

## 请求 / 响应
```
POST http://localhost:10042/v1/chat/completions
Authorization: Bearer pk_echotest_echopass
{"messages":[{"role":"user","content":"Hello from protocol-api L5 test 0624"}],"conversation_id":"l5_echo_0624"}
→ {"id":"f9ecc52774cab1de","object":"chat.completion.pending","retrieve_url":"/v1/chat/completions/f9ecc52774cab1de","status":"processing"}

GET http://localhost:10042/v1/chat/completions/f9ecc52774cab1de
→ {"choices":[{"finish_reason":"stop","index":0,"message":{"content":"echo: Hello from protocol-api L5 test 0624","role":"assistant"}}],"model":"ezagent","object":"chat.completion"}
```

## 结论
✅ protocol-api /v1 OpenAI 兼容端点端到端通:key 鉴权 + 异步 pending/retrieve + dispatch→echo agent→回复取回。
⏳ "codex/curl flavor 真回复"待外部 LLM 凭据(curl→DeepSeek/OpenAI key;codex→F7 需 login)。

---

## L5 补充 — curl flavor 真 LLM 回复 (DeepSeek) via /v1

经专用 e2e harness(`scripts/e2e_init_protocol_api.sh`,隔离 server :10066,host PG 独立 DB,DEEPSEEK_API_KEY)。
**关键修复**:脚本 PORT 只用于 curl 检查未传给 server,首跑隔离 server 撞活 server :10042 绑定失败 → no ack;`export PORT=10066` 后隔离 server 8s 就绪。

结果(scripts/e2e_recordings/e2e-results-20260624-145136.txt):
```
[4a] Echo round 1         ✓ "echo: Hello from ezagent protocol API!"
[4b] Curl+DeepSeek r1     ✓ "Hello in Chinese is \"你好\" (nǐ hǎo)."     ← 真 DeepSeek 回复
[4c] CC round 1          ✗ timeout 60s   (F5 沙箱/spawn)
[4d] Codex round 1       ✗ timeout 60s   (F7 需 codex login)
[5a] Echo round 2         ✓ "echo: Tell me a one-line programming joke"
[5b] Curl+DeepSeek r2     ✓ "2 + 2 equals 4."                          ← 真 DeepSeek 回复
```

## 结论(更新)
✅ protocol-api /v1 端到端(echo,活 :10042)
✅ **curl flavor 真 LLM 回复**(DeepSeek 经 curl agent + /v1,两轮均成功)
✗ cc via /v1 超时(F5 一致) · ✗ codex via /v1 超时(F7 需登录)

---

## L5 终极 — curl flavor 真 DeepSeek 回复 (活 :10042,非隔离)

绕过 F10(无配 key UI):用户授权,直接把 DeepSeek key 写进 test-curl-1 快照的 `:api_keys.state.keys`(`%{"deepseek" => key}`)——curl bridge_adapter 直接从快照存储读该 slice,故生效。铸 `pk_curltest_curlpass` → test-curl-1。

```
POST /v1/chat/completions (Bearer pk_curltest_curlpass) [活 :10042]
  {"messages":[{"role":"user","content":"用中文说一句你好,并说明你是谁"}],"conversation_id":"l5_curl_live_0624"}
→ {"id":"6d15d79df3bad634","object":"chat.completion.pending"}
GET /v1/chat/completions/6d15d79df3bad634
→ {"choices":[{"message":{"role":"assistant","content":
     "你好！我是DeepSeek，一个由深度求索公司创造的AI助手。很高兴认识你，有什么可以帮你的吗？😊"}}],
   "model":"ezagent","object":"chat.completion"}
```

**反证 F10**:后端 curl→DeepSeek→/v1 全链路正常;唯一缺口是配 key 的 UI(本次靠手写 DB 绕过)。
