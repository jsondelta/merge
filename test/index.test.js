import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { merge as mergeFallback } from '../src/fallback.js'

const backends = [['fallback', mergeFallback]]

try {
  const wasm = await import('../src/wasm.js')
  backends.push(['wasm', wasm.merge])
} catch {}

for (const [name, merge] of backends) {
  describe(`merge (${name})`, () => {

    describe('no changes', () => {
      it('all identical', () => {
        const base = { a: 1, b: [2, 3] }
        const result = merge(base, base, base)
        assert.deepStrictEqual(result.doc, base)
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('identical primitives', () => {
        const result = merge(42, 42, 42)
        assert.deepStrictEqual(result.doc, 42)
        assert.deepStrictEqual(result.conflicts, [])
      })
    })

    describe('one-sided changes', () => {
      it('only left changed', () => {
        const base = { a: 1, b: 2 }
        const left = { a: 99, b: 2 }
        const result = merge(base, left, base)
        assert.deepStrictEqual(result.doc, { a: 99, b: 2 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('only right changed', () => {
        const base = { a: 1, b: 2 }
        const right = { a: 1, b: 99 }
        const result = merge(base, base, right)
        assert.deepStrictEqual(result.doc, { a: 1, b: 99 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('left added a key', () => {
        const base = { a: 1 }
        const left = { a: 1, b: 2 }
        const result = merge(base, left, base)
        assert.deepStrictEqual(result.doc, { a: 1, b: 2 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('right removed a key', () => {
        const base = { a: 1, b: 2 }
        const right = { a: 1 }
        const result = merge(base, base, right)
        assert.deepStrictEqual(result.doc, { a: 1 })
        assert.deepStrictEqual(result.conflicts, [])
      })
    })

    describe('non-conflicting changes', () => {
      it('different keys modified', () => {
        const base = { a: 1, b: 2 }
        const left = { a: 99, b: 2 }
        const right = { a: 1, b: 99 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 99, b: 99 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('left adds key, right modifies existing', () => {
        const base = { a: 1 }
        const left = { a: 1, b: 2 }
        const right = { a: 99 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 99, b: 2 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('both add different keys', () => {
        const base = { a: 1 }
        const left = { a: 1, b: 2 }
        const right = { a: 1, c: 3 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 1, b: 2, c: 3 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('nested non-overlapping changes', () => {
        const base = { user: { name: 'alice', role: 'viewer' } }
        const left = { user: { name: 'ALICE', role: 'viewer' } }
        const right = { user: { name: 'alice', role: 'admin' } }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { user: { name: 'ALICE', role: 'admin' } })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('left removes key, right modifies different key', () => {
        const base = { a: 1, b: 2, c: 3 }
        const left = { a: 1, c: 3 }
        const right = { a: 1, b: 2, c: 99 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 1, c: 99 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('different array indices modified', () => {
        const base = [1, 2, 3]
        const left = [99, 2, 3]
        const right = [1, 2, 99]
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, [99, 2, 99])
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('left appends to array, right modifies existing element', () => {
        const base = [1, 2]
        const left = [1, 2, 3]
        const right = [1, 99]
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, [1, 99, 3])
        assert.deepStrictEqual(result.conflicts, [])
      })
    })

    describe('identical changes (no conflict)', () => {
      it('same key modified to same value', () => {
        const base = { a: 1 }
        const left = { a: 2 }
        const right = { a: 2 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 2 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('both add same key with same value', () => {
        const base = {}
        const left = { x: 'hello' }
        const right = { x: 'hello' }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { x: 'hello' })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('both remove same key', () => {
        const base = { a: 1, b: 2 }
        const left = { a: 1 }
        const right = { a: 1 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 1 })
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('both make identical nested change', () => {
        const base = { config: { debug: false } }
        const left = { config: { debug: true } }
        const right = { config: { debug: true } }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { config: { debug: true } })
        assert.deepStrictEqual(result.conflicts, [])
      })
    })

    describe('conflicts', () => {
      it('same key, different values', () => {
        const base = { a: 1 }
        const left = { a: 2 }
        const right = { a: 3 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 1 })
        assert.strictEqual(result.conflicts.length, 1)
        assert.strictEqual(result.conflicts[0].left.op, 'replace')
        assert.deepStrictEqual(result.conflicts[0].left.path, ['a'])
        assert.strictEqual(result.conflicts[0].right.op, 'replace')
        assert.deepStrictEqual(result.conflicts[0].right.path, ['a'])
      })

      it('one modifies, other removes same key', () => {
        const base = { a: 1, b: 2 }
        const left = { a: 1, b: 99 }
        const right = { a: 1 }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 1, b: 2 })
        assert.strictEqual(result.conflicts.length, 1)
        assert.strictEqual(result.conflicts[0].left.op, 'replace')
        assert.strictEqual(result.conflicts[0].right.op, 'remove')
      })

      it('both add same key with different values', () => {
        const base = {}
        const left = { x: 'hello' }
        const right = { x: 'world' }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, {})
        assert.strictEqual(result.conflicts.length, 1)
        assert.strictEqual(result.conflicts[0].left.op, 'add')
        assert.strictEqual(result.conflicts[0].right.op, 'add')
      })

      it('same array index, different values', () => {
        const base = [1, 2, 3]
        const left = [1, 99, 3]
        const right = [1, 77, 3]
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, [1, 2, 3])
        assert.strictEqual(result.conflicts.length, 1)
      })

      it('ancestor/descendant path conflict', () => {
        const base = { a: { b: 1, c: 2 } }
        const left = { a: 'replaced' }
        const right = { a: { b: 99, c: 2 } }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: { b: 1, c: 2 } })
        assert.ok(result.conflicts.length >= 1)
      })

      it('root-level conflict', () => {
        const base = { a: 1 }
        const left = [1, 2]
        const right = 'hello'
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: 1 })
        assert.strictEqual(result.conflicts.length, 1)
      })

      it('conflict preserves base value', () => {
        const base = { x: 'original', y: 1 }
        const left = { x: 'left', y: 2 }
        const right = { x: 'right', y: 2 }
        const result = merge(base, left, right)
        assert.strictEqual(result.doc.x, 'original')
        assert.strictEqual(result.doc.y, 2)
        assert.strictEqual(result.conflicts.length, 1)
        assert.deepStrictEqual(result.conflicts[0].left.path, ['x'])
      })
    })

    describe('complex scenarios', () => {
      it('mix of conflicts and clean changes', () => {
        const base = { a: 1, b: 2, c: 3, d: 4 }
        const left = { a: 10, b: 20, c: 3, d: 4 }
        const right = { a: 10, b: 99, c: 30, d: 4 }
        const result = merge(base, left, right)
        assert.strictEqual(result.doc.a, 10)
        assert.strictEqual(result.doc.b, 2)
        assert.strictEqual(result.doc.c, 30)
        assert.strictEqual(result.doc.d, 4)
        assert.strictEqual(result.conflicts.length, 1)
        assert.deepStrictEqual(result.conflicts[0].left.path, ['b'])
      })

      it('collaborative document editing', () => {
        const base = {
          title: 'Draft',
          sections: [
            { heading: 'Intro', body: 'Hello' },
            { heading: 'Details', body: 'Some details' }
          ],
          metadata: { author: 'alice', version: 1 }
        }
        const left = {
          title: 'Draft',
          sections: [
            { heading: 'Introduction', body: 'Hello' },
            { heading: 'Details', body: 'Some details' }
          ],
          metadata: { author: 'alice', version: 2 }
        }
        const right = {
          title: 'Final',
          sections: [
            { heading: 'Intro', body: 'Hello' },
            { heading: 'Details', body: 'Expanded details here' }
          ],
          metadata: { author: 'alice', version: 1 }
        }
        const result = merge(base, left, right)
        assert.strictEqual(result.doc.title, 'Final')
        assert.strictEqual(result.doc.sections[0].heading, 'Introduction')
        assert.strictEqual(result.doc.sections[1].body, 'Expanded details here')
        assert.strictEqual(result.doc.metadata.version, 2)
        assert.deepStrictEqual(result.conflicts, [])
      })

      it('config merge with partial overlap', () => {
        const base = {
          database: { host: 'localhost', port: 5432 },
          cache: { ttl: 60 },
          logging: { level: 'info' }
        }
        const left = {
          database: { host: 'db.prod', port: 5432 },
          cache: { ttl: 60 },
          logging: { level: 'warn' }
        }
        const right = {
          database: { host: 'localhost', port: 5432 },
          cache: { ttl: 300 },
          logging: { level: 'debug' }
        }
        const result = merge(base, left, right)
        assert.strictEqual(result.doc.database.host, 'db.prod')
        assert.strictEqual(result.doc.cache.ttl, 300)
        assert.strictEqual(result.doc.logging.level, 'info')
        assert.strictEqual(result.conflicts.length, 1)
        assert.deepStrictEqual(result.conflicts[0].left.path, ['logging', 'level'])
      })

      it('deeply nested three-way merge', () => {
        const base = { a: { b: { c: { d: 1, e: 2, f: 3 } } } }
        const left = { a: { b: { c: { d: 10, e: 2, f: 3 } } } }
        const right = { a: { b: { c: { d: 1, e: 2, f: 30 } } } }
        const result = merge(base, left, right)
        assert.deepStrictEqual(result.doc, { a: { b: { c: { d: 10, e: 2, f: 30 } } } })
        assert.deepStrictEqual(result.conflicts, [])
      })
    })

    describe('mutation guards', () => {
      it('does not mutate base, left, or right', () => {
        const base = { a: 1, b: { c: 2 } }
        const left = { a: 99, b: { c: 2 } }
        const right = { a: 1, b: { c: 99 } }
        const baseCopy = JSON.parse(JSON.stringify(base))
        const leftCopy = JSON.parse(JSON.stringify(left))
        const rightCopy = JSON.parse(JSON.stringify(right))
        merge(base, left, right)
        assert.deepStrictEqual(base, baseCopy)
        assert.deepStrictEqual(left, leftCopy)
        assert.deepStrictEqual(right, rightCopy)
      })
    })
  })
}
