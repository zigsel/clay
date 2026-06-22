const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const disable_simd = b.option(
        bool,
        "disable-simd",
        "Disable clay's SIMD-accelerated hashing (default: SIMD enabled)",
    ) orelse false;

    const clay_c = b.dependency("clay_c", .{});

    // Compile the single-header clay implementation into a static library.
    const clay_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wf = b.addWriteFiles();
    const c_flags: []const []const u8 = if (disable_simd)
        &.{ "-std=c99", "-DCLAY_DISABLE_SIMD" }
    else
        &.{"-std=c99"};
    clay_c_mod.addCSourceFile(.{
        .file = wf.add("clay.c",
            \\#define CLAY_IMPLEMENTATION
            \\#include "clay.h"
            \\
        ),
        .flags = c_flags,
    });
    clay_c_mod.addIncludePath(clay_c.path(""));

    const clay_lib = b.addLibrary(.{
        .name = "clay",
        .linkage = .static,
        .root_module = clay_c_mod,
    });

    // The idiomatic Zig binding that consumers import as "clay".
    const clay_mod = b.addModule("clay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    clay_mod.linkLibrary(clay_lib);

    // CLAY_DISABLE_SIMD keeps translate-c away from <arm_neon.h>, which it can't
    // parse; struct layouts are identical with or without SIMD.
    const clay_h = b.addTranslateC(.{
        .root_source_file = clay_c.path("clay.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    clay_h.addIncludePath(clay_c.path(""));
    clay_h.defineCMacro("CLAY_DISABLE_SIMD", null);
    clay_mod.addImport("clay_h", clay_h.createModule());

    const tests = b.addTest(.{ .root_module = clay_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests + ABI conformance checks");
    test_step.dependOn(&run_tests.step);

    // `check` step for fast type-checking in editors / CI.
    const check_tests = b.addTest(.{ .root_module = clay_mod });
    const check = b.step("check", "Type-check the binding without running");
    check.dependOn(&check_tests.step);

    // Compile-check the examples against the public module.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/renderer_skeleton.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("clay", clay_mod);
    const example_tests = b.addTest(.{ .root_module = example_mod });
    const run_example_tests = b.addRunArtifact(example_tests);
    const example_step = b.step("examples", "Compile-check and test the examples");
    example_step.dependOn(&run_example_tests.step);
    test_step.dependOn(&run_example_tests.step);
    check.dependOn(&example_tests.step);
}
