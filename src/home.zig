const web = @import("the_zig_three");
pub const main = web.mainFn(@This());

const Index = @This();

const div: web.Style = .{ .tag = "div" };
const p: web.Style = .{ .tag = "p" };
const p_bold: web.Style = .{ .parent = &p, .bold = true, .class = "bold" };
const p_example: web.Style = .{ .parent = &p_bold, .bold = false, .class = "not_bold" };

const ClientCode = struct {
    text: []const u8,

    pub fn onLoad(root: *web.Unit, self: ClientCode) !void {
        web.log("Test log {s}", .{self.text});

        const browser = web.getBrowser();
        web.log("Hello '{s} user", .{browser});

        try root.add(.{
            p.u(.{self.text}),
        });
    }
};

pub fn onLoad(root: *web.Unit, _: Index) !void {
    try root.add(.{
        div.u(.{
            "example of the new api",
            p_bold.u("this text is bold"),
            p_example.u("this text is not bold"),
        }),
        "Raw text outside a tag",

        web.Script(.client, ClientCode)(.{
            .text = "Example Template",
            //.server = server,
        }),

        web.Script(.generated, @import("footer.zig"))(.{}),
    });
}
