// The web's half of the sections parity run, out of the web's OWN built
// bundle (web-chat/cli/dist/vault.mjs, produced by `node cli/build.mjs` from
// src/lib/sections.ts, which is the code chat.rcq.app ships). Prints the same
// lines main.swift does; run.sh diffs them.
import { readFileSync } from 'node:fs'
import path from 'node:path'

const [dirArg, bundleArg] = process.argv.slice(2)
const { decodeSections, encodeSections, mergeSections } = await import(path.resolve(bundleArg))

const cases = JSON.parse(readFileSync(path.join(dirArg, 'fixtures.json'), 'utf8'))
const enc = new TextEncoder()

// Every key sorted by UTF-8 bytes, at every depth. The counterpart of
// sortedForm() in main.swift: this is the content comparison, not the
// byte-order one. UTF-8 rather than JS `<` (UTF-16 code units) because that is
// the order the merge itself uses on both sides.
const enc8 = new TextEncoder()
function byteLess(a, b) {
  const x = enc8.encode(a)
  const y = enc8.encode(b)
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    if (x[i] !== y[i]) return x[i] - y[i]
  }
  return x.length - y.length
}

function sortedForm(v) {
  if (Array.isArray(v)) return `[${v.map(sortedForm).join(',')}]`
  if (v && typeof v === 'object') {
    const keys = Object.keys(v).sort(byteLess)
    return `{${keys.map((k) => `${JSON.stringify(k)}:${sortedForm(v[k])}`).join(',')}}`
  }
  return JSON.stringify(v) ?? 'null'
}

function watched(tree, spec) {
  const parts = spec.split(':')
  const holder = parts[0] === 'top' ? tree : (tree.s ?? []).find((r) => r.id === parts[1])
  const v = holder ? holder[parts[parts.length - 1]] : undefined
  // Only a container carries a member order, so only a container is compared
  // here; main.swift answers "-" for everything else for the same reason.
  if (!v || typeof v !== 'object') return '-'
  return JSON.stringify(v)
}

const out = []
for (const c of cases) {
  for (const [order, pair] of [
    ['ab', [c.a, c.b]],
    ['ba', [c.b, c.a]],
  ]) {
    const x = decodeSections(enc.encode(pair[0]))
    const y = decodeSections(enc.encode(pair[1]))
    if (!x || !y) {
      out.push(`${c.name}|${order}|decode|FAILED`)
      continue
    }
    const merged = mergeSections(x, y)
    const normal = mergeSections(merged, merged)
    out.push(`${c.name}|${order}|content|${sortedForm(normal)}`)
    for (const p of c.watch) out.push(`${c.name}|${order}|value ${p}|${watched(normal, p)}`)
    // The same tree once through this client's own cache codec, which is where
    // a member order can quietly go missing between two launches.
    const again = decodeSections(encodeSections(normal))
    out.push(`${c.name}|${order}|roundtrip|${again ? sortedForm(again) : 'FAILED'}`)
    for (const p of c.watch) out.push(`${c.name}|${order}|roundtrip ${p}|${again ? watched(again, p) : 'FAILED'}`)
  }
}
process.stdout.write(out.join('\n') + '\n')
