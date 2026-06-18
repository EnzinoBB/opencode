#!/usr/bin/env bun
import { readdirSync, readFileSync, writeFileSync, existsSync } from "fs"
import { join } from "path"

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v)
}

export function mergeConfig(fragments: object[]): object {
  const merge = (target: any, source: any): any => {
    if (!isPlainObject(target) || !isPlainObject(source)) return source
    const out: Record<string, unknown> = { ...target }
    for (const [k, v] of Object.entries(source)) {
      out[k] = k in target ? merge((target as any)[k], v) : v
    }
    return out
  }
  return fragments.reduce((acc, f) => merge(acc, f), {})
}

export function substitute(obj: object, vars: Record<string, string>): object {
  const walk = (v: any): any => {
    if (typeof v === "string") {
      let s = v
      for (const [from, to] of Object.entries(vars)) s = s.split(from).join(to)
      return s
    }
    if (Array.isArray(v)) return v.map(walk)
    if (isPlainObject(v)) {
      const out: Record<string, unknown> = {}
      for (const [k, val] of Object.entries(v)) {
        let nk = k
        for (const [from, to] of Object.entries(vars)) nk = nk.split(from).join(to)
        out[nk] = walk(val)
      }
      return out
    }
    return v
  }
  return walk(obj)
}

function parseConf(path: string): Record<string, string> {
  const vars: Record<string, string> = {}
  if (!existsSync(path)) return vars
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$/)
    if (m) vars[m[1]] = m[2].replace(/^["']|["']$/g, "")
  }
  return vars
}

function main() {
  const [confdir, conf, out] = process.argv.slice(2)
  if (!confdir || !out) {
    console.error("usage: oc-rebuild-config <confdir> <ollama.conf> <out.json>")
    process.exit(2)
  }
  const fragments = readdirSync(confdir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(confdir, f), "utf8")))
  const merged = substitute(mergeConfig(fragments), parseConf(conf))
  writeFileSync(out, JSON.stringify(merged, null, 2) + "\n")
  console.error(`wrote ${out} from ${fragments.length} fragment(s)`)
}

if (import.meta.main) main()
