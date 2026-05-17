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

pub const Attribute = struct {
    key: []const u8,
    value: []const u8,

    pub fn format(self: @This(), writer: *std.io.Writer) !void {
        try writer.print("{s}=\"{s}\"", .{ self.key, self.value });
    }
};

pub const Style = struct {
    tag: ?[]const u8 = null,
    attributes: ?[]const Attribute = null,
    bold: ?bool = null,
    class: ?[]const u8 = null,

    parent: ?*const Style = null,

    pub const html = Style{ .tag = "html" };

    fn GetType(comptime field: []const u8) type {
        return if (std.mem.eql(u8, field, "tag"))
            []const u8
        else if (std.mem.eql(u8, field, "class"))
            []const u8
        else if (std.mem.eql(u8, field, "attributes"))
            []const Attribute
        else if (std.mem.eql(u8, field, "bold"))
            bool
        else
            @compileError("Invalid style property \"" ++ field ++ "\"");
    }

    pub fn get(self: *const Style, comptime field: []const u8) ?GetType(field) {
        return @field(self, field) orelse
            if (self.parent) |parent| parent.get(field) else null;
    }

    fn base(self: Style) bool {
        const info = @typeInfo(Style);
        inline for (info.@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "tag") or
                std.mem.eql(u8, field.name, "class") or
                std.mem.eql(u8, field.name, "attributes"))
                continue;

            if (@field(self, field.name)) |f|
                if (comptime std.mem.eql(u8, field.name, "parent")) {
                    if (!f.base()) return false;
                } else return false;
        }

        return true;
    }

    pub fn u(self: *const Style, children: anytype) Unit {
        var result: Unit = .{
            .data = .{
                .group = .{
                    .style = self,
                },
            },
        };

        result.add(children) catch unreachable;

        return result;
    }

    pub fn text(self: *const Style, txt: []const u8) Unit {
        var result: Unit = .{
            .data = .{
                .group = .{
                    .style = self,
                },
            },
        };

        result.add(.{txt}) catch unreachable;

        return result;
    }

    pub fn format_class(self: Style, writer: *std.io.Writer) std.io.Writer.Error!void {
        if (self.parent) |parent| {
            try parent.format_class(writer);
            if (self.class) |class| {
                try writer.print(" {s}", .{class});
            }
        }
    }

    pub fn format_name(self: Style, writer: *std.io.Writer) std.io.Writer.Error!void {
        if (self.parent) |parent| {
            try parent.format_name(writer);
            if (self.class) |class| {
                try writer.print(".{s}", .{class});
            }
        } else {
            try writer.print("{s}", .{self.tag.?});
        }
    }

    pub fn format(self: Style, writer: *std.io.Writer) std.io.Writer.Error!void {
        if (self.base()) return;

        try self.format_name(writer);
        try writer.print(" {{\n", .{});
        if (self.bold) |bold| try writer.print("    font-weight: {s};\n", .{if (bold) "bold" else "normal"});
        try writer.print("}}\n", .{});
    }
};

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
                                try root.add(.{
                                    (Style{ .tag = "script" }).u(.{
                                        \\WebAssembly.instantiateStreaming(fetch("page.wasm"), {env: {
                                        ,
                                        @embedFile("env.js"),
                                        \\}}).then(
                                        \\   (results) => {
                                        \\       instance = results.instance;
                                        \\       results.instance.exports["_start"]();
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
        const Kind = enum { group, text, generator };

        group: struct {
            style: ?*const Style = null,
            children: std.ArrayList(Unit) = .{},
        },
        text: []const u8,
        generator: Generator,

        pub fn deinit(self: *const Data) void {
            switch (self.*) {
                .group => |g| {
                    for (g.children.items) |child|
                        child.deinit();
                },
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

    pub fn init(new_data: Data) !Unit {
        return .{
            .data = new_data,
        };
    }

    pub fn deinit(self: *const Unit) void {
        self.data.deinit();
    }

    pub fn add(self: *Unit, child: anytype) !void {
        if (!is_runtime) {
            const T = @TypeOf(child);
            const t_info = @typeInfo(T);

            const children: *std.ArrayList(Unit) = switch (self.data) {
                .group => |*g| &g.children,
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
                .@"struct" => |s| {
                    if (s.is_tuple) {
                        inline for (child) |new_child|
                            try self.add(new_child);
                    }
                },
                else => @compileError(@typeName(T) ++ ": " ++ @tagName(t_info)),
            }
        } else {}
    }

    pub fn getStyles(self: Unit) []*const Style {
        switch (self.data) {
            .group => |g| {
                var result: std.ArrayList(*const Style) = .{};
                defer result.deinit(allocator);

                if (g.style) |s|
                    result.append(allocator, s) catch unreachable;

                for (g.children.items) |child| {
                    const styles = child.getStyles();
                    defer allocator.free(styles);

                    result.appendSlice(allocator, styles) catch unreachable;
                }

                return result.toOwnedSlice(allocator) catch unreachable;
            },
            .text => return &.{},
            .generator => |gen| {
                var tmp = try Unit.init(.{
                    .group = .{},
                });
                defer tmp.deinit();

                gen.generate(&tmp, gen.base) catch unreachable;
                return tmp.getStyles();
            },
        }
    }

    // Basic zig format function, outputs in html.
    pub fn format(self: @This(), writer: *std.io.Writer) !void {
        switch (self.data) {
            .group => |g| {
                if (g.style) |style| {
                    try writer.print("<{s}", .{style.get("tag") orelse "p"});
                    if (style.get("attributes")) |attrs| {
                        for (attrs) |attr|
                            try writer.print(" {f}", .{attr});
                    }

                    try writer.print(" class=\"", .{});
                    try style.format_class(writer);

                    try writer.print("\">", .{});
                }

                for (g.children.items) |child|
                    try writer.print("{f}", .{child});

                if (g.style) |style| {
                    try writer.print("</{s}>", .{style.get("tag") orelse "p"});
                }
            },
            .text => |t| try writer.print("{s}", .{t}),
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

pub const Document = struct {
    root: Unit,

    // NOTE: This adds a single html element
    pub fn init() !Document {
        const root = try Unit.init(.{
            .group = .{
                .style = &.html,
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

    pub fn getStyles(self: Document) []*const Style {
        return self.root.getStyles();
    }
};

pub fn mainFn(Root: type) fn () anyerror!void {
    const result = struct {
        pub fn exported() callconv(.c) void {
            _ = Root.onLoad(undefined, undefined) catch unreachable;
        }

        pub fn main() !void {
            if (!is_runtime) {
                const args = try std.process.argsAlloc(allocator);

                const cli = flags.parse(
                    args,
                    "generator",

                    struct {
                        positional: struct {
                            html_output_path: []const u8,
                            css_output_path: []const u8,
                        },
                    },

                    .{},
                );

                var document = try Document.init();
                defer document.deinit();

                const params = Root{};

                try document.root.add((Style{ .tag = "head" }).u(.{
                    (Style{
                        .tag = "link",
                        .attributes = &.{
                            .{ .key = "rel", .value = "stylesheet" },
                            .{ .key = "href", .value = "/index.css" },
                        },
                    }).u(.{}),
                }));

                try Root.onLoad(&document.root, params);

                var html_file: std.fs.File = try std.fs.createFileAbsolute(cli.positional.html_output_path, .{});
                defer html_file.close();

                var html_writer = html_file.writer(&.{});
                try html_writer.interface.print("{f}", .{document});

                var css_file: std.fs.File = try std.fs.createFileAbsolute(cli.positional.css_output_path, .{});
                defer css_file.close();

                var css_writer = css_file.writer(&.{});

                for (document.getStyles()) |style|
                    try css_writer.interface.print("{f}", .{style});
            }
        }
    };

    if (is_runtime)
        @export(&result.exported, .{ .name = "stub", .linkage = .link_once });

    return result.main;
}
