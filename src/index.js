import { merge as fallbackMerge } from './fallback.js'

let merge = fallbackMerge
let backend = 'fallback'

try {
  const wasm = await import('./wasm.js')
  merge = wasm.merge
  backend = 'wasm'
} catch {
  // using fallback
}

export { merge, backend }
