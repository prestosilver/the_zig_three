const std = @import("std");
const flags = @import("flags");
const builtin = @import("builtin");

var generation: bool = true;
const client_pass = builtin.target.cpu.arch == .wasm32;

fn gen_pass() enum {
    generation,
    script,
    server,
} {
    return if (generation == true)
        .generation
    else
        .script;
}

var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

var js_body: std.ArrayList(u8) = .{};
var idx: usize = 0;

pub fn jsValue(comptime name: []const u8, comptime gen: anytype, comptime code: []const u8) gen {
    idx += 1;

    if (comptime client_pass)
        return @extern(gen, .{ .name = name });

    switch (gen_pass()) {
        .script => {
            const gen_code = std.fmt.allocPrint(allocator, "{s}: {s},", .{ name, code }) catch unreachable;
            defer allocator.free(gen_code);

            js_body.appendSlice(allocator, gen_code) catch unreachable;

            return undefined;
        },
        .server, .generation => {
            return undefined;
        },
    }
}

export fn allocate(len: usize) callconv(.c) [*]const u8 {
    return (allocator.alloc(u8, len) catch unreachable).ptr;
}

pub fn getBrowser() []const u8 {
    const useragent_fn = jsValue(
        "getBrowser",
        *const fn () callconv(.c) [*:0]const u8,
        \\() => {
        \\    const myString = navigator.userAgent;
        \\    const encoder = new TextEncoder();
        \\    const bytes = encoder.encode(myString);
        \\    
        \\    // Assume Wasm module exports an 'allocate' function
        \\    const ptr = wasm_instance.exports.allocate(bytes.length);
        \\    const view = new Uint8Array(wasm_instance.exports.memory.buffer, ptr, bytes.length);
        \\    view.set(bytes);
        \\
        \\    return ptr;
        \\}
        ,
    );

    if (comptime client_pass) {
        return std.mem.span(useragent_fn());
    } else {
        switch (gen_pass()) {
            .script => return "",
            else => |p| std.debug.panic("Cannot call get browser in {s} pass.", .{@tagName(p)}),
        }
    }
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    const log_fn = jsValue(
        "logFunction",
        *const fn (ptr: [*c]const u8, len: usize) callconv(.c) void,
        \\(ptr,len) => {
        \\    const memory = new Uint8Array(wasm_instance.exports.memory.buffer);
        \\    const msg = new TextDecoder().decode(memory.subarray(ptr, ptr + len));
        \\    console.log(msg);
        \\}
        ,
    );

    if (comptime client_pass) {
        const msg = std.fmt.allocPrint(allocator, fmt, args) catch unreachable;
        defer allocator.free(msg);

        return log_fn(msg.ptr, msg.len);
    } else {
        switch (gen_pass()) {
            .server, .generation => std.log.info(fmt, args),
            .script => {},
            //else => |p| std.debug.panic("Cannot call log in {s} pass.", .{@tagName(p)}),
        }
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
                                //const elem = get_unit(generator_name.ptr, generator_name.len);
                                Base.onLoad(undefined, base) catch unreachable;
                            }

                            comptime {
                                if (client_pass) {
                                    @export(&exported, .{ .name = generator_name });
                                }
                            }

                            pub fn onLoad(root: *Unit, base_ptr: *const anyopaque) !void {
                                const b: *const Base = @ptrCast(@alignCast(base_ptr));
                                generation = false;
                                _ = try Base.onLoad(root, b.*);
                                generation = true;

                                try root.add(.{
                                    (Style{
                                        .tag = "script",
                                        .attributes = &.{
                                            .{ .key = "type", .value = "module" },
                                        },
                                    }).u(.{
                                        \\import {wasm_instance} from '/index.js';
                                        \\wasm_instance.exports["
                                        ++ @typeName(Base) ++
                                            \\"]();
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
                                const b: *const Base = @ptrCast(@alignCast(base_ptr));
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
        if (!client_pass) {
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
            if (!client_pass) {
                const args = try std.process.argsAlloc(allocator);

                const cli = flags.parse(
                    args,
                    "generator",

                    struct {
                        positional: struct {
                            html_output_path: []const u8,
                            css_output_path: []const u8,
                            js_output_path: []const u8,
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

                var js_file: std.fs.File = try std.fs.createFileAbsolute(cli.positional.js_output_path, .{});
                defer js_file.close();

                var js_writer = js_file.writer(&.{});

                try js_writer.interface.writeAll(
                    \\export const wasm_instance = await new Promise((resolve) => {
                    \\  WebAssembly.instantiateStreaming(fetch("page.wasm"), {env: {
                    ,
                );
                try js_writer.interface.writeAll(js_body.items);

                try js_writer.interface.writeAll(
                    \\  }}).then((result) => {
                    \\    result.instance.exports["_start"]();
                    \\    resolve(result.instance);
                    \\  });
                    \\});
                );

                var css_file: std.fs.File = try std.fs.createFileAbsolute(cli.positional.css_output_path, .{});
                defer css_file.close();

                var css_writer = css_file.writer(&.{});

                for (document.getStyles()) |style|
                    try css_writer.interface.print("{f}", .{style});
            }
        }
    };

    if (client_pass)
        @export(&result.exported, .{ .name = "stub", .linkage = .link_once });

    return result.main;
}
