const web = @import("the_zig_three");
pub const main = web.mainFn(@This());

const Index = @This();

const client_script = web.Script(.client, Example);

comptime {
    _ = client_script;
}

const Example = struct {
    text: []const u8,
    //server: *web.Unit,

    pub fn onLoad(root: *web.Unit, self: Example) !void {
        //const serverText = self.server.call("getHello", .{});
        web.log("Test log", .{});

        try root.addChildren(.{
            web.Tag("p", .{self.text}),
            // web.Tag("p", .{ "server says: ", serverText }),
        });
    }
};

const Server = struct {
    pub fn getHello(_: *web.Unit, _: Server) []const u8 {
        return "Hello World!";
    }

    // onload should not be required
};

pub fn onLoad(root: *web.Unit, _: Index) !void {
    // Since servers are a unit, you can @import it and keep the code seperate.
    // const server = web.Script(.server, Server)(.{});

    try root.addChildren(.{
        web.Tag("h1", .{"Example of the new api"}),
        client_script(.{
            .text = "Example Template",
            //.server = server,
        }),
        // server,

        // templates if it wasnt obvious from the previous post, can be made with @import
        web.Script(.generated, @import("footer.zig"))(.{}),
    });
}
