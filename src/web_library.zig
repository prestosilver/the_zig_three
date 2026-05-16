const std = @import("std");
const flags = @import("flags");
const builtin = @import("builtin");

const is_runtime = builtin.target.cpu.arch == .wasm32;

var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

extern fn get_unit(ptr: [*]const u8, len: usize) *Unit;

pub fn getBrowser() []const u8 {
    return "Chrome";
}

extern fn console_log(ptr: [*]const u8, len: usize) void;
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (is_runtime) {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
        console_log(msg.ptr, msg.len);
    } else {
        std.log.info(fmt, args);
    }
}

const Generator = struct {
    base: *const anyopaque,
    generate: *const fn (*Unit, base: *const anyopaque) anyerror!void,
    name: []const u8,
};

const ScriptKind = enum { generated, client, server };
pub fn Script(comptime kind: ScriptKind, comptime Base: type) fn (comptime base: Base) Generator {
    return struct {
        pub fn gen(comptime base: Base) Generator {
            const generator_name = b: {
                break :b std.fmt.comptimePrint("{s}", .{@typeName(Base)});
            };

            switch (comptime kind) {
                .server => @compileError("Server code is not yet implemented"),
                .client => {
                    return .{
                        .base = @ptrCast(&base),
                        .name = generator_name,
                        .generate = struct {
                            pub fn exported() callconv(.c) void {
                                const elem = get_unit(generator_name.ptr, generator_name.len);
                                Base.onLoad(elem, base) catch unreachable;
                            }

                            comptime {
                                if (is_runtime) {
                                    @export(&exported, .{ .name = generator_name });
                                }
                            }

                            pub fn onLoad(root: *Unit, _: *const anyopaque) !void {
                                try root.addChildren(.{
                                    Tag("script", .{
                                        \\WebAssembly.instantiateStreaming(fetch("page.wasm"), {env: {
                                        ,
                                        @embedFile("env.js"),
                                        \\}}).then(
                                        \\   (results) => {
                                        \\       instance = results.instance;
                                        \\       results.instance.exports["
                                        ++ @typeName(Base) ++
                                            \\"]();},);
                                    }),
                                });
                            }
                        }.onLoad,
                    };
                },
                .generated => {
                    return Generator{
                        .base = @ptrCast(&base),
                        .name = generator_name,
                        .generate = &struct {
                            pub fn onLoad(root: *Unit, base_ptr: *const anyopaque) !void {
                                const b: *const Base = @ptrCast(base_ptr);
                                return Base.onLoad(root, b.*);
                            }
                        }.onLoad,
                    };
                },
            }
        }
    }.gen;
}

pub const Unit = struct {
    const Data = union(Kind) {
        const Kind = enum { group, tag, attribute, text, generator };

        group: struct {
            children: std.ArrayList(Unit) = .{},
        },
        tag: struct {
            kind: []const u8,
            children: std.ArrayList(Unit) = .{},
        },
        attribute: struct {
            key: []const u8,
            value: []const u8,
        },
        text: []const u8,
        generator: Generator,

        pub fn deinit(self: *const Data) void {
            switch (self.*) {
                .group => |g| {
                    for (g.children.items) |child|
                        child.deinit();
                },
                .tag => |t| {
                    for (t.children.items) |child|
                        child.deinit();
                },
                .attribute => {},
                .text => {},
                .generator => |gen| {
                    _ = gen;
                    // gen.deinit();
                },
            }
        }
    };

    data: Data,

    const Error = error{ InvalidParentType, OutOfMemory };

    pub fn text(t: []const u8) Data {
        return .{
            .text = t,
        };
    }

    pub fn attribute(key: []const u8, value: []const u8) Data {
        return .{ .attribute = .{
            .key = key,
            .value = value,
        } };
    }

    pub fn init(new_data: Data) !Unit {
        return .{
            .data = new_data,
        };
    }

    pub fn deinit(self: *const Unit) void {
        self.data.deinit();
    }

    pub fn addChild(self: *Unit, child: anytype) !void {
        if (!is_runtime) {
            const T = @TypeOf(child);
            const t_info = @typeInfo(T);

            const children: *std.ArrayList(Unit) = switch (self.data) {
                .group => |*g| &g.children,
                .tag => |*t| &t.children,
                else => |o| {
                    std.log.err("Unit type {s} cannot have chilren", .{@tagName(o)});

                    return error.BadParent;
                },
            };

            if (comptime std.meta.eql(T, Unit.Data)) {
                try children.append(allocator, .{ .data = child });
            } else if (comptime std.meta.eql(T, Unit)) {
                try children.append(allocator, child);
            } else if (comptime std.meta.eql(T, Generator)) {
                try children.append(allocator, .{ .data = .{ .generator = child } });
            } else switch (comptime t_info) {
                .pointer => |p| {
                    const child_info = @typeInfo(p.child);

                    if (comptime std.meta.eql(p.child, u8) and p.size == .slice) {
                        try children.append(allocator, .{ .data = .{ .text = child } });
                    } else if (p.size == .one and child_info == .array and comptime std.meta.eql(child_info.array.child, u8)) {
                        try children.append(allocator, .{ .data = .{ .text = child } });
                    } else @compileError(std.fmt.comptimePrint("{any}", .{p}));
                },
                else => @compileError(@typeName(T) ++ ": " ++ @tagName(t_info)),
            }
        }
    }

    pub fn addChildren(self: *Unit, children: anytype) anyerror!void {
        inline for (children) |new_child|
            try self.addChild(new_child);
    }

    // Basic zig format function, outputs in html.
    pub fn format(self: @This(), writer: *std.io.Writer) !void {
        switch (self.data) {
            .group => |g| {
                for (g.children.items) |child|
                    try writer.print("{f}", .{child});
            },
            .tag => |t| {
                var body: std.io.Writer.Allocating = .init(allocator);
                defer body.deinit();
                var attrs: std.io.Writer.Allocating = .init(allocator);
                defer attrs.deinit();

                for (t.children.items) |child| {
                    if (child.data == .attribute)
                        try attrs.writer.print(" {f}", .{child})
                    else
                        try body.writer.print("{f}", .{child});
                }

                const body_slice = body.toOwnedSlice() catch return error.WriteFailed;
                defer allocator.free(body_slice);
                const attrs_slice = attrs.toOwnedSlice() catch return error.WriteFailed;
                defer allocator.free(attrs_slice);

                if (body_slice.len == 0) {
                    try writer.print("<{s}{s}/>", .{ t.kind, attrs_slice });
                } else {
                    try writer.print("<{s}{s}>\n{s}</{s}>\n", .{ t.kind, attrs_slice, body_slice, t.kind });
                }
            },
            .attribute => |attr| {
                try writer.print("{s}=\"{s}\"", .{ attr.key, attr.value });
            },
            .text => |t| try writer.print("{s}\n", .{t}),
            .generator => |gen| {
                var tmp = try Unit.init(.{
                    .group = .{},
                });
                defer tmp.deinit();

                gen.generate(&tmp, gen.base) catch unreachable;

                try writer.print("{f}", .{tmp});
            },
        }
    }
};

pub fn Tag(kind: []const u8, children: anytype) Unit {
    var result: Unit = .{
        .data = .{
            .tag = .{
                .kind = kind,
                .children = .{},
            },
        },
    };

    result.addChildren(children) catch unreachable;

    return result;
}

pub const Document = struct {
    root: Unit,

    // NOTE: This adds a single html element
    pub fn init() !Document {
        const root = try Unit.init(.{
            .tag = .{
                .kind = "html",
                .children = try .initCapacity(allocator, 0),
            },
        });

        return .{
            .root = root,
        };
    }

    pub fn deinit(self: *const Document) void {
        self.root.deinit();
    }

    // Basic zig format function, outputs in html.
    pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print("{f}", .{self.root});
    }
};

pub fn mainFn(Root: type) fn () anyerror!void {
    return struct {
        pub fn exported() callconv(.c) void {
            _ = Root.onLoad(undefined, undefined) catch unreachable;
        }

        comptime {
            if (is_runtime)
                @export(&exported, .{ .name = "stub" });
        }

        pub fn main() !void {
            if (!is_runtime) {
                const args = try std.process.argsAlloc(allocator);

                const cli = flags.parse(
                    args,
                    "generator",

                    struct {
                        positional: struct {
                            output_path: []const u8,
                        },
                    },

                    .{},
                );

                var document = try Document.init();
                defer document.deinit();

                const params = Root{};

                try Root.onLoad(&document.root, params);

                var file: std.fs.File = try std.fs.createFileAbsolute(cli.positional.output_path, .{});
                defer file.close();

                var writer = file.writer(&.{});
                try writer.interface.print("{f}", .{document});
            }
        }
    }.main;
}
