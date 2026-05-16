const web = @import("web_library");
pub const main = web.mainFn(@This());

comptime {
    // TODO : dont require this
    _ = web.Generator.init("p", .runtime, example);
}

pub const example = struct {
    pub fn onLoad(root: *web.Element) !void {
        _ = root;

        web.log("Hello from zig!");
    }

    // TODO: get working
    fn onClick() void {
        web.log("user clicked!");
    }
};

pub fn onLoad(root: *web.Element) !void {
    try root.addChildren(&.{
        .initTag("head", &.{
            .initTag("title", &.{.initText("Prestosilver test page")}),
        }),
        .initTag("body", &.{
            .initTag("h1", &.{.initText("This is a test page.")}),
            .initTag("a", &.{
                .initAttribute("href", "http://prestosilver.info"),
                .initText("Link"),
            }),
            .initGen("p", .runtime, example),
            .initGen("p", .generated, struct {
                pub fn onLoad(element_root: *web.Element) !void {
                    try element_root.addChildren(&.{
                        .initText("How are you today"),
                    });
                }
            }),
            .initTag("p", &.{.initText("Ok tkx bye")}),
        }),
    });
}
