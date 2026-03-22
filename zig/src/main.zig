const std = @import("std");
const json = std.json;
const Writer = std.io.Writer;

const ally = std.heap.wasm_allocator;

var result_data: ?[]u8 = null;

export fn alloc(len: usize) ?[*]u8 {
    const slice = ally.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn dealloc(ptr: [*]u8, len: usize) void {
    ally.free(ptr[0..len]);
}

export fn getResultPtr() ?[*]const u8 {
    if (result_data) |d| return d.ptr;
    return null;
}

export fn getResultLen() usize {
    if (result_data) |d| return d.len;
    return 0;
}

export fn freeResult() void {
    if (result_data) |d| {
        ally.free(d);
        result_data = null;
    }
}

// --- types ---

const PathSegment = union(enum) {
    key: []const u8,
    index: usize,
};

const PathBuf = struct {
    segments: [64]PathSegment = undefined,
    len: usize = 0,

    fn push(self: *PathBuf, seg: PathSegment) void {
        if (self.len < 64) {
            self.segments[self.len] = seg;
            self.len += 1;
        }
    }

    fn pop(self: *PathBuf) void {
        if (self.len > 0) self.len -= 1;
    }

    fn slice(self: *const PathBuf) []const PathSegment {
        return self.segments[0..self.len];
    }
};

const OpKind = enum { add, remove, replace };

const InternalOp = struct {
    kind: OpKind,
    path: []const PathSegment,
    value: json.Value,
    old_value: json.Value,
    new_value: json.Value,
};

const Conflict = struct {
    left: InternalOp,
    right: InternalOp,
};

const MergeError = error{OutOfMemory};

// --- wasm export ---

export fn merge(
    base_ptr: [*]const u8,
    base_len: usize,
    left_ptr: [*]const u8,
    left_len: usize,
    right_ptr: [*]const u8,
    right_len: usize,
) i32 {
    const base_parsed = json.parseFromSlice(json.Value, ally, base_ptr[0..base_len], .{}) catch return -1;
    defer base_parsed.deinit();

    const left_parsed = json.parseFromSlice(json.Value, ally, left_ptr[0..left_len], .{}) catch return -1;
    defer left_parsed.deinit();

    const right_parsed = json.parseFromSlice(json.Value, ally, right_ptr[0..right_len], .{}) catch return -1;
    defer right_parsed.deinit();

    const result = mergeInternal(base_parsed.value, left_parsed.value, right_parsed.value) catch return -1;

    var aw: Writer.Allocating = .init(ally);
    errdefer aw.deinit();

    var jw: json.Stringify = .{ .writer = &aw.writer };
    writeResult(&jw, result.doc, result.conflicts) catch return -1;
    aw.writer.flush() catch return -1;
    const out = aw.toOwnedSlice() catch return -1;
    result_data = out;
    return @intCast(out.len);
}

const MergeResult = struct {
    doc: json.Value,
    conflicts: []const Conflict,
};

fn mergeInternal(base: json.Value, left: json.Value, right: json.Value) MergeError!MergeResult {
    var left_ops: std.ArrayList(InternalOp) = .{};
    defer left_ops.deinit(ally);
    var right_ops: std.ArrayList(InternalOp) = .{};
    defer right_ops.deinit(ally);

    var path: PathBuf = .{};
    try diffInternal(base, left, &path, &left_ops);
    path.len = 0;
    try diffInternal(base, right, &path, &right_ops);

    if (left_ops.items.len == 0 and right_ops.items.len == 0) {
        return .{ .doc = try deepClone(base), .conflicts = &.{} };
    }
    if (left_ops.items.len == 0) {
        return .{ .doc = try deepClone(right), .conflicts = &.{} };
    }
    if (right_ops.items.len == 0) {
        return .{ .doc = try deepClone(left), .conflicts = &.{} };
    }

    var clean_left: std.ArrayList(InternalOp) = .{};
    defer clean_left.deinit(ally);
    var clean_right: std.ArrayList(InternalOp) = .{};
    defer clean_right.deinit(ally);
    var conflicts: std.ArrayList(Conflict) = .{};
    defer conflicts.deinit(ally);

    var right_consumed = std.AutoHashMap(usize, void).init(ally);
    defer right_consumed.deinit();

    for (left_ops.items) |l_op| {
        var has_conflict = false;
        var has_equal = false;

        for (right_ops.items, 0..) |r_op, ri| {
            if (!pathsOverlap(l_op.path, r_op.path)) continue;

            try right_consumed.put(ri, {});

            if (internalOpsEqual(l_op, r_op)) {
                has_equal = true;
            } else {
                has_conflict = true;
                try conflicts.append(ally, .{ .left = l_op, .right = r_op });
            }
        }

        if (!has_conflict) {
            if (has_equal) {
                try clean_left.append(ally, l_op);
            } else {
                try clean_left.append(ally, l_op);
            }
        }
    }

    for (right_ops.items, 0..) |r_op, ri| {
        if (!right_consumed.contains(ri)) {
            try clean_right.append(ally, r_op);
        }
    }

    const total_clean = clean_left.items.len + clean_right.items.len;
    var all_clean: std.ArrayList(InternalOp) = .{};
    defer all_clean.deinit(ally);
    try all_clean.ensureTotalCapacity(ally, total_clean);
    for (clean_left.items) |op| all_clean.appendAssumeCapacity(op);
    for (clean_right.items) |op| all_clean.appendAssumeCapacity(op);

    const doc = if (all_clean.items.len > 0)
        try applyCleanOps(base, all_clean.items)
    else
        try deepClone(base);

    const conflicts_owned = try ally.dupe(Conflict, conflicts.items);

    return .{ .doc = doc, .conflicts = conflicts_owned };
}

// --- diff logic ---

fn valuesEqual(a: json.Value, b: json.Value) bool {
    const a_tag: u8 = @intFromEnum(a);
    const b_tag: u8 = @intFromEnum(b);
    if (a_tag != b_tag) return false;

    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .array => |a_arr| {
            const b_arr = b.array;
            if (a_arr.items.len != b_arr.items.len) return false;
            for (a_arr.items, b_arr.items) |ai, bi| {
                if (!valuesEqual(ai, bi)) return false;
            }
            return true;
        },
        .object => |a_obj| {
            const b_obj = b.object;
            if (a_obj.count() != b_obj.count()) return false;
            var it = a_obj.iterator();
            while (it.next()) |entry| {
                if (b_obj.get(entry.key_ptr.*)) |bv| {
                    if (!valuesEqual(entry.value_ptr.*, bv)) return false;
                } else return false;
            }
            return true;
        },
    };
}

fn diffInternal(a: json.Value, b: json.Value, path: *PathBuf, ops: *std.ArrayList(InternalOp)) MergeError!void {
    if (valuesEqual(a, b)) return;

    const a_tag: u8 = @intFromEnum(a);
    const b_tag: u8 = @intFromEnum(b);

    if (a_tag != b_tag) {
        const p = try ally.dupe(PathSegment, path.slice());
        try ops.append(ally, .{ .kind = .replace, .path = p, .value = .null, .old_value = a, .new_value = b });
        return;
    }

    switch (a) {
        .object => |a_obj| {
            const b_obj = b.object;

            var a_it = a_obj.iterator();
            while (a_it.next()) |entry| {
                path.push(.{ .key = entry.key_ptr.* });
                if (b_obj.get(entry.key_ptr.*)) |b_val| {
                    try diffInternal(entry.value_ptr.*, b_val, path, ops);
                } else {
                    const p = try ally.dupe(PathSegment, path.slice());
                    try ops.append(ally, .{ .kind = .remove, .path = p, .value = entry.value_ptr.*, .old_value = .null, .new_value = .null });
                }
                path.pop();
            }

            var b_it = b_obj.iterator();
            while (b_it.next()) |entry| {
                if (!a_obj.contains(entry.key_ptr.*)) {
                    path.push(.{ .key = entry.key_ptr.* });
                    const p = try ally.dupe(PathSegment, path.slice());
                    try ops.append(ally, .{ .kind = .add, .path = p, .value = entry.value_ptr.*, .old_value = .null, .new_value = .null });
                    path.pop();
                }
            }
        },
        .array => |a_arr| {
            const b_arr = b.array;
            const max = @max(a_arr.items.len, b_arr.items.len);
            for (0..max) |i| {
                path.push(.{ .index = i });
                if (i >= a_arr.items.len) {
                    const p = try ally.dupe(PathSegment, path.slice());
                    try ops.append(ally, .{ .kind = .add, .path = p, .value = b_arr.items[i], .old_value = .null, .new_value = .null });
                } else if (i >= b_arr.items.len) {
                    const p = try ally.dupe(PathSegment, path.slice());
                    try ops.append(ally, .{ .kind = .remove, .path = p, .value = a_arr.items[i], .old_value = .null, .new_value = .null });
                } else {
                    try diffInternal(a_arr.items[i], b_arr.items[i], path, ops);
                }
                path.pop();
            }
        },
        else => {
            const p = try ally.dupe(PathSegment, path.slice());
            try ops.append(ally, .{ .kind = .replace, .path = p, .value = .null, .old_value = a, .new_value = b });
        },
    }
}

// --- merge helpers ---

fn pathsOverlap(a: []const PathSegment, b: []const PathSegment) bool {
    const min = @min(a.len, b.len);
    for (0..min) |i| {
        if (!segmentsEqual(a[i], b[i])) return false;
    }
    return true;
}

fn segmentsEqual(a: PathSegment, b: PathSegment) bool {
    return switch (a) {
        .key => |ak| switch (b) {
            .key => |bk| std.mem.eql(u8, ak, bk),
            .index => false,
        },
        .index => |ai| switch (b) {
            .key => false,
            .index => |bi| ai == bi,
        },
    };
}

fn internalOpsEqual(a: InternalOp, b: InternalOp) bool {
    if (a.kind != b.kind) return false;
    if (a.path.len != b.path.len) return false;
    for (a.path, b.path) |as, bs| {
        if (!segmentsEqual(as, bs)) return false;
    }
    return switch (a.kind) {
        .add, .remove => valuesEqual(a.value, b.value),
        .replace => valuesEqual(a.old_value, b.old_value) and valuesEqual(a.new_value, b.new_value),
    };
}

// --- patch logic (apply clean ops to base) ---

fn applyCleanOps(doc: json.Value, ops: []const InternalOp) MergeError!json.Value {
    if (ops.len == 0) return deepClone(doc);

    var last_root: ?InternalOp = null;
    for (ops) |op| {
        if (op.path.len == 0) last_root = op;
    }

    if (last_root) |root| {
        return switch (root.kind) {
            .replace => deepClone(root.new_value),
            .add => deepClone(root.value),
            .remove => .null,
        };
    }

    switch (doc) {
        .array => |arr| return rebuildArray(arr, ops),
        .object => |obj| return rebuildObject(obj, ops),
        else => return deepClone(doc),
    }
}

fn rebuildArray(arr: json.Array, ops: []const InternalOp) MergeError!json.Value {
    var removes = std.AutoHashMap(usize, void).init(ally);
    defer removes.deinit();

    const AddEntry = struct { idx: usize, value: json.Value };
    var adds: std.ArrayList(AddEntry) = .{};
    defer adds.deinit(ally);

    const SubEntry = struct { idx: usize, op: InternalOp };
    var subs: std.ArrayList(SubEntry) = .{};
    defer subs.deinit(ally);

    for (ops) |op| {
        if (op.path.len == 0) continue;
        const idx = op.path[0].index;
        const sub = InternalOp{
            .kind = op.kind,
            .path = op.path[1..],
            .value = op.value,
            .old_value = op.old_value,
            .new_value = op.new_value,
        };

        if (sub.path.len == 0 and sub.kind == .remove) {
            try removes.put(idx, {});
        } else if (sub.path.len == 0 and sub.kind == .add and idx >= arr.items.len) {
            try adds.append(ally, .{ .idx = idx, .value = sub.value });
        } else {
            try subs.append(ally, .{ .idx = idx, .op = sub });
        }
    }

    var result = json.Array.init(ally);

    for (arr.items, 0..) |item, i| {
        if (removes.contains(i)) continue;

        var child_ops: std.ArrayList(InternalOp) = .{};
        defer child_ops.deinit(ally);
        for (subs.items) |entry| {
            if (entry.idx == i) try child_ops.append(ally, entry.op);
        }

        if (child_ops.items.len > 0) {
            try result.append(try applyCleanOps(item, child_ops.items));
        } else {
            try result.append(try deepClone(item));
        }
    }

    std.mem.sort(AddEntry, adds.items, {}, struct {
        fn lessThan(_: void, a: AddEntry, b_: AddEntry) bool {
            return a.idx < b_.idx;
        }
    }.lessThan);

    for (adds.items) |entry| {
        try result.append(try deepClone(entry.value));
    }

    return .{ .array = result };
}

fn rebuildObject(obj: json.ObjectMap, ops: []const InternalOp) MergeError!json.Value {
    var removes = std.StringHashMap(void).init(ally);
    defer removes.deinit();

    const AddEntry = struct { key: []const u8, value: json.Value };
    var adds: std.ArrayList(AddEntry) = .{};
    defer adds.deinit(ally);

    const SubEntry = struct { key: []const u8, op: InternalOp };
    var subs: std.ArrayList(SubEntry) = .{};
    defer subs.deinit(ally);

    for (ops) |op| {
        if (op.path.len == 0) continue;
        const key = op.path[0].key;
        const sub = InternalOp{
            .kind = op.kind,
            .path = op.path[1..],
            .value = op.value,
            .old_value = op.old_value,
            .new_value = op.new_value,
        };

        if (sub.path.len == 0 and sub.kind == .remove) {
            try removes.put(key, {});
        } else if (sub.path.len == 0 and sub.kind == .add and !obj.contains(key)) {
            try adds.append(ally, .{ .key = key, .value = sub.value });
        } else {
            try subs.append(ally, .{ .key = key, .op = sub });
        }
    }

    var new_obj = json.ObjectMap.init(ally);

    var it = obj.iterator();
    while (it.next()) |entry| {
        if (removes.contains(entry.key_ptr.*)) continue;

        var child_ops: std.ArrayList(InternalOp) = .{};
        defer child_ops.deinit(ally);
        for (subs.items) |sub_entry| {
            if (std.mem.eql(u8, sub_entry.key, entry.key_ptr.*)) {
                try child_ops.append(ally, sub_entry.op);
            }
        }

        const k = try ally.dupe(u8, entry.key_ptr.*);
        if (child_ops.items.len > 0) {
            try new_obj.put(k, try applyCleanOps(entry.value_ptr.*, child_ops.items));
        } else {
            try new_obj.put(k, try deepClone(entry.value_ptr.*));
        }
    }

    for (adds.items) |entry| {
        const k = try ally.dupe(u8, entry.key);
        try new_obj.put(k, try deepClone(entry.value));
    }

    return .{ .object = new_obj };
}

fn deepClone(val: json.Value) MergeError!json.Value {
    return switch (val) {
        .null, .bool, .integer, .float => val,
        .string => |s| .{ .string = try ally.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try ally.dupe(u8, s) },
        .array => |arr| {
            var new_arr = json.Array.init(ally);
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try deepClone(item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = json.ObjectMap.init(ally);
            try new_obj.ensureTotalCapacity(@intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try ally.dupe(u8, entry.key_ptr.*);
                new_obj.putAssumeCapacity(key, try deepClone(entry.value_ptr.*));
            }
            return .{ .object = new_obj };
        },
    };
}

// --- serialization ---

fn writeResult(jw: *json.Stringify, doc: json.Value, conflicts: []const Conflict) !void {
    try jw.beginObject();

    try jw.objectField("doc");
    try jw.write(doc);

    try jw.objectField("conflicts");
    try jw.beginArray();
    for (conflicts) |c| {
        try jw.beginObject();
        try jw.objectField("left");
        try writeInternalOp(jw, c.left);
        try jw.objectField("right");
        try writeInternalOp(jw, c.right);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeInternalOp(jw: *json.Stringify, op: InternalOp) !void {
    try jw.beginObject();

    try jw.objectField("op");
    try jw.write(switch (op.kind) {
        .add => "add",
        .remove => "remove",
        .replace => "replace",
    });

    try jw.objectField("path");
    try jw.beginArray();
    for (op.path) |seg| {
        switch (seg) {
            .key => |k| try jw.write(k),
            .index => |i| try jw.write(i),
        }
    }
    try jw.endArray();

    switch (op.kind) {
        .add, .remove => {
            try jw.objectField("value");
            try jw.write(op.value);
        },
        .replace => {
            try jw.objectField("old");
            try jw.write(op.old_value);
            try jw.objectField("new");
            try jw.write(op.new_value);
        },
    }

    try jw.endObject();
}
