<p align="center">
  <img src="logo.svg" width="128" height="128" alt="@jsondelta/merge">
</p>

<h1 align="center">@jsondelta/merge</h1>

<p align="center">
  Zig-powered three-way JSON merge with conflict detection. Merge concurrent edits, detect collisions, keep the base value for conflicts.
</p>

<p align="center">
  <a href="https://github.com/jsondelta/merge/actions/workflows/test.yml"><img src="https://github.com/jsondelta/merge/actions/workflows/test.yml/badge.svg" alt="test"></a>
  <a href="https://www.npmjs.com/package/@jsondelta/merge"><img src="https://img.shields.io/npm/v/@jsondelta/merge" alt="npm"></a>
</p>

## Install

```
npm install @jsondelta/merge
```

## Usage

```js
import { merge } from '@jsondelta/merge'

const base = { title: 'Draft', body: 'Hello', status: 'open' }
const left = { title: 'Draft', body: 'Hello world', status: 'open' }
const right = { title: 'Final', body: 'Hello', status: 'review' }

const { doc, conflicts } = merge(base, left, right)
// doc: { title: 'Final', body: 'Hello world', status: 'review' }
// conflicts: []
```

The default import selects the fastest available backend: WebAssembly or pure JS fallback. You can also import a specific backend directly:

```js
import { merge } from '@jsondelta/merge/fallback'
import { merge } from '@jsondelta/merge/wasm'
```

## Real-world examples

### Merging concurrent edits in a collaborative editor

```js
import { merge } from '@jsondelta/merge'

const base = {
  title: 'Q1 Report',
  sections: [
    { heading: 'Revenue', body: 'Revenue grew 12% YoY.' },
    { heading: 'Costs', body: 'Operating costs remained flat.' }
  ],
  metadata: { author: 'alice', version: 1 }
}

// alice updates the revenue figure and bumps the version
const alice = {
  title: 'Q1 Report',
  sections: [
    { heading: 'Revenue', body: 'Revenue grew 15% YoY, beating estimates.' },
    { heading: 'Costs', body: 'Operating costs remained flat.' }
  ],
  metadata: { author: 'alice', version: 2 }
}

// bob updates the title and costs section
const bob = {
  title: 'Q1 Financial Report',
  sections: [
    { heading: 'Revenue', body: 'Revenue grew 12% YoY.' },
    { heading: 'Costs', body: 'Operating costs decreased 3%.' }
  ],
  metadata: { author: 'alice', version: 1 }
}

const { doc, conflicts } = merge(base, alice, bob)
// doc.title === 'Q1 Financial Report'
// doc.sections[0].body === 'Revenue grew 15% YoY, beating estimates.'
// doc.sections[1].body === 'Operating costs decreased 3%.'
// doc.metadata.version === 2
// conflicts === []
```

### Merging configuration with conflict detection

```js
import { merge } from '@jsondelta/merge'

const base = { database: { host: 'localhost', port: 5432 }, logging: { level: 'info' } }
const staging = { database: { host: 'staging.db', port: 5432 }, logging: { level: 'debug' } }
const production = { database: { host: 'prod.db', port: 5432 }, logging: { level: 'warn' } }

const { doc, conflicts } = merge(base, staging, production)
// doc.database.host stays 'localhost' (conflict - both changed it differently)
// doc.logging.level stays 'info' (conflict)
// conflicts.length === 2
```

## API

### `merge(base, left, right)`

Three-way merge of JSON-compatible values.

- `base` - the common ancestor
- `left` - the left (or "ours") revision
- `right` - the right (or "theirs") revision
- Returns `{ doc, conflicts }`

**`doc`** contains all non-conflicting changes applied to the base. Conflicting paths retain the base value - neither side wins automatically.

**`conflicts`** is an array of conflict objects, each with `left` and `right` properties containing the conflicting operations from each side. Operations follow the `@jsondelta/diff` delta format:

```js
{
  left: { op: 'replace', path: ['level'], old: 'info', new: 'debug' },
  right: { op: 'replace', path: ['level'], old: 'info', new: 'warn' }
}
```

When both sides make the same change to the same path, it is not a conflict - the change is applied once.

## Conflict detection

Two operations conflict when their paths overlap (one is a prefix of the other, or they are equal) and the operations differ.

| Left | Right | Result |
|------|-------|--------|
| Changes `a.b` | Changes `a.c` | Both applied (no overlap) |
| Changes `a.b` to X | Changes `a.b` to X | Applied once (identical) |
| Changes `a.b` to X | Changes `a.b` to Y | Conflict |
| Replaces `a` entirely | Changes `a.b` | Conflict (ancestor/descendant) |
| Removes `a.b` | Changes `a.b` | Conflict |

## How it works

The merge engine is written in Zig and compiled to WebAssembly. It diffs the base against both revisions, partitions the resulting operations into clean (non-overlapping) and conflicting sets, and applies the clean operations to produce the merged document.

The pure JS fallback uses `@jsondelta/diff` and `@jsondelta/patch` under the hood.

**Architecture:**
1. **WebAssembly** - Self-contained Zig engine with embedded diff and patch logic. Near-native speed, no JS dependencies at runtime
2. **Pure JS fallback** - Uses `@jsondelta/diff` and `@jsondelta/patch`. Always works

## License

MIT
