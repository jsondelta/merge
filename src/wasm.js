import { readFileSync } from 'fs'
import { fileURLToPath } from 'url'
import { dirname, join } from 'path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const wasmPath = join(__dirname, '..', 'wasm', 'merge.wasm')
const wasmBuffer = readFileSync(wasmPath)
const wasmModule = new WebAssembly.Module(wasmBuffer)
const wasmInstance = new WebAssembly.Instance(wasmModule)
const wasm = wasmInstance.exports

const encoder = new TextEncoder()
const decoder = new TextDecoder()

function callWasm(fn, ...jsonArgs) {
  const buffers = jsonArgs.map(arg => encoder.encode(JSON.stringify(arg)))
  const ptrs = buffers.map(buf => {
    const ptr = wasm.alloc(buf.length)
    if (!ptr) throw new Error('wasm allocation failed')
    new Uint8Array(wasm.memory.buffer).set(buf, ptr)
    return { ptr, len: buf.length }
  })

  const args = ptrs.flatMap(p => [p.ptr, p.len])
  const resultLen = fn(...args)

  for (const p of ptrs) wasm.dealloc(p.ptr, p.len)

  if (resultLen < 0) throw new Error('wasm merge failed')

  const resultPtr = wasm.getResultPtr()
  const resultBytes = new Uint8Array(wasm.memory.buffer.slice(resultPtr, resultPtr + resultLen))
  const result = JSON.parse(decoder.decode(resultBytes))

  wasm.freeResult()
  return result
}

/**
 * Three-way merge of JSON-compatible values using the Zig WASM engine.
 * @param {*} base - Common ancestor
 * @param {*} left - Left revision
 * @param {*} right - Right revision
 * @returns {{ doc: *, conflicts: Array<{ left: Object, right: Object }> }}
 */
function merge(base, left, right) {
  return callWasm(wasm.merge, base, left, right)
}

export { merge }
