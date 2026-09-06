// The web side of the cross-island parity check: the web's OWN built bundle,
// not a transcription. `node cli/build.mjs` bundles web-chat/src/lib/
// crossisland-vault.ts into cli/dist/vault.mjs and this imports the merge out
// of it.
import { readFileSync } from 'node:fs'

const dir = process.argv[2]
const bundle = process.argv[3]
const { mergeCrossIsland, canonState } = await import(bundle)
const cases = JSON.parse(readFileSync(dir + '/fixtures.json', 'utf8'))

const state = (text) => {
  const j = JSON.parse(text)
  return { v: 1, c: j.c || {}, g: j.g || {} }
}
const out = (s) => JSON.stringify(canonState(s))

for (const c of cases) {
  const a = state(c.a)
  const b = state(c.b)
  const ab = mergeCrossIsland(a, b, c.now)
  const ba = mergeCrossIsland(b, a, c.now)
  console.log(`${c.name}\t${out(ab)}`)
  console.log(`${c.name} [reversed]\t${out(ba)}`)
  console.log(`${c.name} [twice]\t${out(mergeCrossIsland(ab, ab, c.now))}`)
}
