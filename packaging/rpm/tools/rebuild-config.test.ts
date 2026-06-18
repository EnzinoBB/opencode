import { test, expect } from "bun:test"
import { mergeConfig, substitute } from "./rebuild-config"

test("deep-merges lsp records by key", () => {
  const a = { lsp: { pyright: { command: ["x"] } }, provider: { ollama: { name: "O" } } }
  const b = { lsp: { bash: { command: ["y"] } } }
  expect(mergeConfig([a, b])).toEqual({
    lsp: { pyright: { command: ["x"] }, bash: { command: ["y"] } },
    provider: { ollama: { name: "O" } },
  })
})

test("later fragment overrides scalar and replaces arrays", () => {
  expect(mergeConfig([{ a: 1, arr: [1, 2] }, { a: 2, arr: [9] }])).toEqual({ a: 2, arr: [9] })
})

test("substitute replaces tokens inside string values only", () => {
  const out = substitute(
    { provider: { ollama: { options: { baseURL: "http://OLLAMA_HOST:OLLAMA_PORT/v1" }, models: { MODEL_ID: {} } } } },
    { OLLAMA_HOST: "10.0.0.5", OLLAMA_PORT: "11434", MODEL_ID: "qwen2.5-coder" },
  )
  expect(out).toEqual({
    provider: { ollama: { options: { baseURL: "http://10.0.0.5:11434/v1" }, models: { "qwen2.5-coder": {} } } },
  })
})
