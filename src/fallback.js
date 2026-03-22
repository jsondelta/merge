import { diff } from '@jsondelta/diff/fallback'
import { patch } from '@jsondelta/patch/fallback'

/**
 * Three-way merge of JSON-compatible values.
 * @param {*} base - Common ancestor
 * @param {*} left - Left revision
 * @param {*} right - Right revision
 * @returns {{ doc: *, conflicts: Array<{ left: Object, right: Object }> }}
 */
function merge(base, left, right) {
  const leftDelta = diff(base, left)
  const rightDelta = diff(base, right)

  if (leftDelta.length === 0 && rightDelta.length === 0) {
    return { doc: structuredClone(base), conflicts: [] }
  }
  if (leftDelta.length === 0) {
    return { doc: structuredClone(right), conflicts: [] }
  }
  if (rightDelta.length === 0) {
    return { doc: structuredClone(left), conflicts: [] }
  }

  const conflicts = []
  const cleanLeft = []
  const rightConsumed = new Set()

  for (const lOp of leftDelta) {
    let hasConflict = false

    for (let ri = 0; ri < rightDelta.length; ri++) {
      const rOp = rightDelta[ri]
      if (!pathsOverlap(lOp.path, rOp.path)) continue

      rightConsumed.add(ri)

      if (opsEqual(lOp, rOp)) {
        if (!hasConflict) cleanLeft.push(lOp)
        hasConflict = 'equal'
      } else {
        hasConflict = true
        conflicts.push({ left: lOp, right: rOp })
      }
    }

    if (!hasConflict) {
      cleanLeft.push(lOp)
    }
  }

  const cleanRight = []
  for (let ri = 0; ri < rightDelta.length; ri++) {
    if (!rightConsumed.has(ri)) cleanRight.push(rightDelta[ri])
  }

  const cleanOps = [...cleanLeft, ...cleanRight]
  const doc = cleanOps.length > 0 ? patch(base, cleanOps) : structuredClone(base)

  return { doc, conflicts }
}

function pathsOverlap(a, b) {
  const min = Math.min(a.length, b.length)
  for (let i = 0; i < min; i++) {
    if (a[i] !== b[i]) return false
  }
  return true
}

function opsEqual(a, b) {
  if (a.op !== b.op) return false
  if (!pathsEqual(a.path, b.path)) return false
  if (a.op === 'replace') return deepEqual(a.old, b.old) && deepEqual(a.new, b.new)
  return deepEqual(a.value, b.value)
}

function pathsEqual(a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false
  }
  return true
}

function deepEqual(a, b) {
  if (a === b) return true
  if (a === null || b === null) return a === b
  if (typeof a !== typeof b) return false
  if (typeof a !== 'object') return false

  const aArr = Array.isArray(a)
  const bArr = Array.isArray(b)
  if (aArr !== bArr) return false

  if (aArr) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false
    }
    return true
  }

  const aKeys = Object.keys(a)
  const bKeys = Object.keys(b)
  if (aKeys.length !== bKeys.length) return false
  for (const key of aKeys) {
    if (!(key in b) || !deepEqual(a[key], b[key])) return false
  }
  return true
}

export { merge }
