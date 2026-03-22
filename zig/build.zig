const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "merge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        }),
    });

    exe.root_module.export_symbol_names = &.{
        "alloc",
        "dealloc",
        "merge",
        "getResultPtr",
        "getResultLen",
        "freeResult",
    };
    exe.entry = .disabled;

    b.installArtifact(exe);
}
