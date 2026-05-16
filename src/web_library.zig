const std = @import("std");
const flags = @import("flags");
const builtin = @import("builtin");

const is_runtime = builtin.target.cpu.arch == .wasm32;

extern fn get_element(ptr: [*]const u8, len: usize) *Element;

pub fn getBrowser() []const u8 {
    return "Chrome";
}

extern fn console_log(ptr: [*]const u8, len: usize) void;
pub fn log(msg: []const u8) void {
    if (is_runtime) {
        console_log(msg.ptr, msg.len);
    } else {
        std.log.info("{s}", .{msg});
    }
}

pub const Generator = struct {
    const Kind = enum { runtime, generated };

    tag: []const u8,
    generate: *const fn (*Element) anyerror!void,
    name: []const u8,

    pub fn init(tag: []const u8, comptime kind: Kind, comptime Base: type) Generator {
        const generator_name = b: {
            break :b std.fmt.comptimePrint("{s}", .{@typeName(Base)});
        };

        switch (comptime kind) {
            .runtime => {
                return .{
                    .tag = tag,
                    .name = generator_name,
                    .generate = struct {
                        pub fn exported() callconv(.c) void {
                            const elem = get_element(generator_name.ptr, generator_name.len);
                            Base.onLoad(elem) catch unreachable;
                        }

                        comptime {
                            if (is_runtime) {
                                @export(&exported, .{ .name = generator_name });
                            }
                        }

                        pub fn onLoad(root: *Element) !void {
                            try root.addChildren(&.{
                                .initTag("script", &.{
                                    .initText(
                                        \\WebAssembly.instantiateStreaming(fetch("page.wasm"), {env: {
                                    ++ @embedFile("env.js") ++
                                        \\}}).then(
                                        \\   (results) => {
                                        \\       instance = results.instance;
                                        \\       results.instance.exports["
                                    ++ @typeName(Base) ++
                                        \\"]();
                                        \\   },
                                        \\);
                                    ),
                                }),
                            });
                        }
                    }.onLoad,
                };
            },
            .generated => {
                return .{
                    .tag = tag,
                    .name = generator_name,
                    .generate = &Base.onLoad,
                };
            },
        }
    }
};

pub const Element = struct {
    const Data = union(Kind) {
        const Kind = enum { tag, element_tag, attribute, text, generator };

        tag: struct {
            kind: []const u8,
            children: []const Data,
        },
        element_tag: struct {
            kind: []const u8,
            children: std.ArrayList(Element),
        },
        attribute: struct {
            key: []const u8,
            value: []const u8,
        },
        text: []const u8,
        generator: Generator,

        pub fn initText(text: []const u8) Data {
            return .{
                .text = text,
            };
        }

        pub fn initTag(kind: []const u8, children: []const Data) Data {
            return .{
                .tag = .{
                    .kind = kind,
                    .children = children,
                },
            };
        }

        pub fn initGen(tag: []const u8, comptime kind: Generator.Kind, Base: anytype) Data {
            return .{
                .generator = .init(tag, kind, Base),
            };
        }

        pub fn initAttribute(key: []const u8, value: []const u8) Data {
            return .{ .attribute = .{
                .key = key,
                .value = value,
            } };
        }

        pub fn deinit(self: *const Data) void {
            switch (self.*) {
                .tag => {},
                .element_tag => |tag| {
                    for (tag.children.items) |child|
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

    allocator: std.mem.Allocator,
    data: Data,

    const Error = error{ InvalidParentType, OutOfMemory };

    pub fn init(new_allocator: std.mem.Allocator, new_data: Data) !Element {
        return .{
            .allocator = new_allocator,
            .data = new_data,
        };
    }

    pub fn deinit(self: *const Element) void {
        self.data.deinit();
    }

    pub fn addChild(self: *Element, child: Data) !void {
        if (self.data != .element_tag) return error.InvalidParentType;

        if (child == .tag) {
            var new_child = try Element.init(self.allocator, .{
                .element_tag = .{
                    .kind = child.tag.kind,
                    .children = undefined,
                },
            });
            new_child.data.element_tag.children = try .initCapacity(self.allocator, child.tag.children.len);
            try new_child.addChildren(child.tag.children);

            try self.data.element_tag.children.append(self.allocator, new_child);
        } else {
            const new_child = try Element.init(self.allocator, child);
            try self.data.element_tag.children.append(self.allocator, new_child);
        }
    }

    pub fn addChildren(self: *Element, children: []const Data) Error!void {
        for (children) |new_child|
            try self.addChild(new_child);
    }

    // Basic zig format function, outputs in html.
    pub fn format(self: @This(), writer: *std.io.Writer) !void {
        switch (self.data) {
            .tag => unreachable,
            .element_tag => |tag| {
                var body: std.io.Writer.Allocating = .init(self.allocator);
                defer body.deinit();
                var attrs: std.io.Writer.Allocating = .init(self.allocator);
                defer attrs.deinit();

                for (tag.children.items) |child| {
                    if (child.data == .attribute)
                        try attrs.writer.print(" {f}", .{child})
                    else
                        try body.writer.print("{f}", .{child});
                }

                const body_slice = body.toOwnedSlice() catch return error.WriteFailed;
                defer self.allocator.free(body_slice);
                const attrs_slice = attrs.toOwnedSlice() catch return error.WriteFailed;
                defer self.allocator.free(attrs_slice);

                if (body_slice.len == 0) {
                    try writer.print("<{s}{s}/>", .{ tag.kind, attrs_slice });
                } else {
                    try writer.print("<{s}{s}>\n{s}</{s}>\n", .{ tag.kind, attrs_slice, body_slice, tag.kind });
                }
            },
            .attribute => |attr| {
                try writer.print("{s}=\"{s}\"", .{ attr.key, attr.value });
            },
            .text => |t| try writer.print("{s}\n", .{t}),
            .generator => |gen| {
                var tmp = try Element.init(self.allocator, .{
                    .element_tag = .{
                        .kind = gen.tag,
                        .children = std.ArrayList(Element).initCapacity(self.allocator, 0) catch unreachable,
                    },
                });
                defer tmp.deinit();

                tmp.addChild(.initAttribute("id", gen.name)) catch unreachable;

                gen.generate(&tmp) catch unreachable;

                try writer.print("{f}", .{tmp});
            },
        }
    }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    root: Element,

    // NOTE: This adds a single html element
    pub fn init(new_allocator: std.mem.Allocator) !Document {
        const root = try Element.init(new_allocator, .{
            .element_tag = .{
                .kind = "html",
                .children = try .initCapacity(new_allocator, 0),
            },
        });

        return .{
            .allocator = new_allocator,
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

pub fn mainFn(Root: anytype) fn () anyerror!void {
    return struct {
        pub fn main() !void {
            if (!is_runtime) {
                var gpa = std.heap.DebugAllocator(.{}){};
                const allocator = gpa.allocator();

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

                var document = try Document.init(allocator);
                defer document.deinit();

                try Root.onLoad(&document.root);

                std.log.info("Writing to {s}\n", .{cli.positional.output_path});
                var file: std.fs.File = try std.fs.createFileAbsolute(cli.positional.output_path, .{});
                defer file.close();

                var writer = file.writer(&.{});
                try writer.interface.print("{f}", .{document});
            }
        }
    }.main;
}
