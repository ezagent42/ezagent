import {expect, test, type Page} from "@playwright/test"
import generatedFixtures from "./fixtures/world.e2e.fixtures.json" with {type: "json"}

type RecordedEvent = {event: string; payload: Record<string, unknown>}

const sessionsFixtureUri = generatedFixtures.fixtures.sessions.state.current_session_uri
const conversationFixtureUri = generatedFixtures.fixtures.conversation.state.session_uri

async function openFixture(page: Page, fixture: string) {
  await page.goto(`/?fixture=${fixture}`)
  await expect(page.locator("html")).toHaveAttribute("data-world-e2e-ready", "true")
  await expect(page.locator("[data-world-mount-error]")).toHaveCount(0)
}

async function recordedEvents(page: Page): Promise<RecordedEvent[]> {
  return page.evaluate(() => window.__WORLD_E2E__.events)
}

async function lastEvent(page: Page): Promise<RecordedEvent> {
  const events = await recordedEvents(page)
  expect(events.length).toBeGreaterThan(0)
  return events.at(-1) as RecordedEvent
}

test.beforeEach(async ({context}) => {
  await context.route("**/*", async (route) => {
    const url = new URL(route.request().url())
    if (url.hostname !== "127.0.0.1" && url.hostname !== "localhost") {
      await route.abort("blockedbyclient")
      return
    }
    await route.continue()
  })
})

const rendererMatrix = [
  ["sessions", "sessions_table"],
  ["conversation", "conversation"],
  ["pty", "pty_terminal"],
  ["overview", "overview"],
  ["admin", "dashboard"],
  ["workspace_plugins", "workspaces_list"],
] as const

for (const [fixture, component] of rendererMatrix) {
  test(`renders ${fixture} from the generated contract fixture`, async ({page}) => {
    await openFixture(page, fixture)
    await expect(page.locator(`[data-world-component="${component}"]`)).toBeVisible()
    await expect(page.locator("[data-world-shell]")).toBeVisible()
  })
}

test("renders the registered kanban plugin family", async ({page}) => {
  await openFixture(page, "kanban")
  await expect(page.getByRole("heading", {name: "看板 · 配置"})).toBeVisible()
})

test("all four primary navigation entries emit world:navigate", async ({page}) => {
  await openFixture(page, "sessions")

  const expected = [
    ["Chat", `/sessions?session=${encodeURIComponent(sessionsFixtureUri)}`],
    ["Agents", "/identities/agents"],
    ["Manage", "/workspaces"],
    ["Overview", "/overview"],
  ] as const

  for (const [label, to] of expected) {
    await page.evaluate(() => window.__WORLD_E2E__.clearEvents())
    await page.getByRole("navigation", {name: "Primary"}).getByRole("link", {name: label}).click()
    await expect.poll(() => lastEvent(page)).toEqual({event: "world:navigate", payload: {to}})
  }
})

test("sessions interaction emits an admitted world:dispatch", async ({page}) => {
  await openFixture(page, "sessions")
  await page.locator("[data-world-session-rail]").getByRole("button", {name: /Alpha Support/}).click()

  await expect.poll(() => lastEvent(page)).toEqual({
    event: "world:dispatch",
    payload: {action: "sessions.join", args: {session_uri: sessionsFixtureUri}},
  })
  expect(await page.evaluate(() => window.__WORLD_E2E__.contractViolation())).toBeNull()
})

test("sessions create form emits session.create", async ({page}) => {
  await openFixture(page, "sessions")
  await page.getByRole("button", {name: "新建会话"}).click()
  await page.getByLabel("名称").fill("tier-1-room")
  await page.getByRole("button", {name: "创建", exact: true}).click()

  await expect.poll(() => lastEvent(page)).toEqual({
    event: "world:dispatch",
    payload: {
      action: "session.create",
      args: {short_name: "tier-1-room", template_name: "support"},
    },
  })
  expect(await page.evaluate(() => window.__WORLD_E2E__.contractViolation())).toBeNull()
})

test("conversation composer emits chat.send", async ({page}) => {
  await openFixture(page, "conversation")
  await page.getByLabel("消息").fill("Tier-1 hello")
  await page.getByRole("button", {name: "发送"}).click()

  await expect.poll(() => lastEvent(page)).toEqual({
    event: "world:dispatch",
    payload: {
      action: "chat.send",
      args: {session_uri: conversationFixtureUri, text: "Tier-1 hello", grants: []},
    },
  })
  expect(await page.evaluate(() => window.__WORLD_E2E__.contractViolation())).toBeNull()
})

test("credential admission uses public dispatch and joins the returned provisional member", async ({page}) => {
  const attemptId = "attempt-e2e-llm"
  const provisionalAgentUri = "entity://acme/agent/hello-llm-provisional"

  await openFixture(page, "conversation")

  const admission = page.locator('[data-world-agent-admission="llm"]')
  await expect(admission).toBeVisible()
  await admission.getByRole("button", {name: "Configure API key"}).click()

  await expect.poll(() => lastEvent(page)).toEqual({
    event: "world:dispatch",
    payload: {
      action: "session.agent_admission.begin",
      args: {session_uri: conversationFixtureUri, role_name: "llm"},
    },
  })

  await page.evaluate(
    ({attemptId, provisionalAgentUri}) =>
      window.__WORLD_E2E__.emit("world:state", {
        ...window.__WORLD_E2E__.contract.fixtures.conversation.state,
        agent_admissions: [
          {
            role_name: "llm",
            status: "authenticating",
            attempt_id: attemptId,
            provisional_agent_uri: provisionalAgentUri,
            connection: {kind: "api_key", label: "Configure API key", provider: "deepseek"},
          },
        ],
      }),
    {attemptId, provisionalAgentUri},
  )

  await admission.getByRole("button", {name: "完成 Configure API key"}).click()

  await expect.poll(() => lastEvent(page)).toEqual({
    event: "world:dispatch",
    payload: {
      action: "session.agent_admission.complete",
      args: {session_uri: conversationFixtureUri, role_name: "llm", attempt_id: attemptId},
    },
  })

  await page.evaluate(
    ({attemptId, provisionalAgentUri}) => {
      window.__WORLD_E2E__.emit("world:state", {
        ...window.__WORLD_E2E__.contract.fixtures.conversation.state,
        agent_admissions: [
          {
            role_name: "llm",
            status: "joined",
            attempt_id: attemptId,
            provisional_agent_uri: provisionalAgentUri,
            connection: {kind: "api_key", label: "Configure API key", provider: "deepseek"},
          },
        ],
      })
      window.__WORLD_E2E__.emit("members:update", {
        members: [{uri: provisionalAgentUri, display_name: provisionalAgentUri, kind: "agent"}],
      })
    },
    {attemptId, provisionalAgentUri},
  )

  await expect(admission).toHaveCount(0)
  await page.getByRole("button", {name: "展开成员面板"}).click()
  await expect(page.getByText(provisionalAgentUri, {exact: true})).toBeVisible()
  expect(await page.evaluate(() => window.__WORLD_E2E__.contractViolation())).toBeNull()
})

test("registered plugin interaction emits an admitted kanban action", async ({page}) => {
  await openFixture(page, "kanban")
  await page.getByLabel("Access Token").fill("fixture-token")
  await page.getByRole("button", {name: "保存凭证"}).click()

  await expect.poll(() => lastEvent(page)).toEqual({
    event: "world:dispatch",
    payload: {action: "kanban.save_miro_creds", args: {access_token: "fixture-token"}},
  })
  expect(await page.evaluate(() => window.__WORLD_E2E__.contractViolation())).toBeNull()
})

test("world:state server reply replaces layout and rerenders", async ({page}) => {
  await openFixture(page, "sessions")
  await expect(page.locator('[data-world-component="sessions_table"]')).toBeVisible()

  await page.evaluate(() => window.__WORLD_E2E__.transitionTo("admin"))

  await expect(page.locator('[data-world-component="dashboard"]')).toBeVisible()
  await expect(page.locator('[data-world-component="sessions_table"]')).toHaveCount(0)
})

declare global {
  interface Window {
    __WORLD_E2E__: {
      clearEvents: () => void
      contractViolation: () => string | null
      events: RecordedEvent[]
      transitionTo: (name: string) => void
    }
  }
}
