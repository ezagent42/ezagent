import {describe, expect, it, vi} from "vitest"

// @ts-expect-error The LiveView hook is plain browser JavaScript.
import {WorldRenderer} from "../js/world_renderer.js"

describe("WorldRenderer caller refresh", () => {
  it("forwards LiveView's refreshed workspace list to the mounted React island", () => {
    const setCaller = vi.fn()
    const previousCaller = JSON.stringify({workspaces: []})
    const refreshedCaller = JSON.stringify({workspaces: [{name: "system", uri: "workspace://system"}]})

    const hook = {
      el: {dataset: {caller: refreshedCaller, lastDispatch: ""}},
      _lastCallerJson: previousCaller,
      _lastDispatchStatus: null,
      _world: {setCaller, setDispatchStatus: vi.fn()},
    }

    WorldRenderer.updated.call(hook)

    expect(setCaller).toHaveBeenCalledOnce()
    expect(setCaller).toHaveBeenCalledWith({
      workspaces: [{name: "system", uri: "workspace://system"}],
    })
  })
})
