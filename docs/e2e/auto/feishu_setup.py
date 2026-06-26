#!/usr/bin/env python3
"""docs/e2e/auto/feishu_setup.py — 为 scenario-11 合成入站建绑定(幂等)

直插 PG 两张投影/绑定表,让一个 POST 到 /api/feishu/webhook 的合成事件能完整路由:
  - feishu_user_bindings:  假 open_id → 一个真实 user(过 SenderResolver,否则 {:pending} 不路由)
  - external_mirror_bindings: 假 chat_id → 目标 session(过 InboundChatLookup)

用假 chat_id(出站镜像发往它会无害失败,不打扰真飞书群)。pip install pg8000。

  python3.12 feishu_setup.py <session_uri> <open_id> <chat_id> <user_uri>
退出码 0=ok / 2=环境未就绪。
"""
import os, sys
try:
    import pg8000.native as pg
except Exception:
    print("SKIP: 无 pg8000"); sys.exit(2)

sess, open_id, chat_id, user_uri = (sys.argv + ["","","",""])[1:5]
sess = sess or "session://system/default/e2e-auto"
open_id = open_id or "ou_e2e_fake"
chat_id = chat_id or "oc_e2e_fake"
user_uri = user_uri or "entity://system/user/admin"

def env(k, d=None):
    v = os.environ.get(k, d)
    if v is None: print(f"SKIP: 缺 {k}"); sys.exit(2)
    return v
try:
    c = pg.Connection(user=env("POSTGRES_USER"), password=env("POSTGRES_PASSWORD"),
                      host=env("POSTGRES_HOST","127.0.0.1"), port=int(env("POSTGRES_PORT","5432")),
                      database=env("POSTGRES_DB"))
except Exception as e:
    print(f"SKIP: 连不上 PG ({e})"); sys.exit(2)

c.run("""insert into feishu_user_bindings (open_id,user_uri,bound_by,bound_at)
         values (:o,:u,:u,(now() at time zone 'UTC'))
         on conflict (open_id) do update set user_uri=excluded.user_uri""", o=open_id, u=user_uri)
c.run("""insert into external_mirror_bindings
         (id,session_uri,adapter_id,target_id,opts_json,bound_by,bound_at,workspace_uri,inserted_at,updated_at)
         values (:id,:s,'feishu',:t,'{}',:u,(now() at time zone 'UTC'),'workspace://system',
                 (now() at time zone 'UTC'),(now() at time zone 'UTC'))
         on conflict (session_uri,adapter_id,target_id) do nothing""",
      id="e2e-fake-bind-"+chat_id, s=sess, t=chat_id, u=user_uri)
print(f"ok: open_id {open_id}->{user_uri}; chat {chat_id}->{sess}")
sys.exit(0)
