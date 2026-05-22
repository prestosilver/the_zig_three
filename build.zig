const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags_dep = b.dependency("flags", .{
        .target = target,
        .optimize = optimize,
    });

    const flags_mod = flags_dep.module("flags");

    const web_library_mod = b.addModule("the_zig_three", .{
        .root_source_file = b.path("src/web_library.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "flags", .module = flags_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "home_generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/home.zig"),
            .target = target,
            .optimize = optimize,

            .imports = &.{
                .{ .name = "the_zig_three", .module = web_library_mod },
            },
        }),
    });

    const generate_cmd = b.addRunArtifact(exe);
    generate_cmd.step.dependOn(b.getInstallStep());
    const generated_html_file = generate_cmd.addOutputFileArg("index.html");
    const generated_css_file = generate_cmd.addOutputFileArg("index.css");
    const generated_js_file = generate_cmd.addOutputFileArg("index.js");

    const generated_html_artifact = b.addInstallFile(generated_html_file, "index.html");
    const generated_css_artifact = b.addInstallFile(generated_css_file, "index.css");
    const generated_js_artifact = b.addInstallFile(generated_js_file, "index.js");

    const web_library_mod_wasm = b.addModule("the_zig_three_wasm", .{
        .root_source_file = b.path("src/web_library.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .imports = &.{
            .{ .name = "flags", .module = flags_mod },
        },
    });

    const web_mod = b.addModule("page", .{
        .root_source_file = b.path("src/home.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .imports = &.{
            .{ .name = "the_zig_three", .module = web_library_mod_wasm },
        },
        .optimize = optimize,
    });

    const web_lib = b.addExecutable(.{
        .name = "page",
        .root_module = web_mod,
    });
    web_lib.entry = .disabled;
    web_lib.rdynamic = true;

    const wasm_artifact = b.addInstallArtifact(web_lib, .{
        .dest_dir = .{
            .override = .prefix,
        },
    });
    const generate_step = b.step("generate", "Generate the website");

    generate_step.dependOn(&wasm_artifact.step);
    generate_step.dependOn(&generated_html_artifact.step);
    generate_step.dependOn(&generated_css_artifact.step);
    generate_step.dependOn(&generated_js_artifact.step);
}
