import {shadcnComponentDefinitions} from "@json-render/shadcn/catalog"
import {describe, expect, it} from "vitest"

import {catalog} from "./catalog"

describe("hello catalog", () => {
  it("keeps the complete official 36-component shadcn contract", () => {
    const officialComponents = Object.keys(shadcnComponentDefinitions).sort()
    const catalogComponents = [...catalog.componentNames].sort()

    expect(officialComponents).toHaveLength(36)
    expect(catalogComponents).toEqual(officialComponents)
  })

  it("does not expose undeclared client actions", () => {
    expect(catalog.actionNames).toEqual([])
  })
})
