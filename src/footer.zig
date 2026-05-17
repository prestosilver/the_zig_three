const web = @import("the_zig_three");
pub const main = web.mainFn(@This());

const Footer = @This();

pub fn onLoad(root: *web.Unit, _: Footer) !void {
    try root.add((web.Style{ .tag = "p" }).u(.{
        "Footer",
    }));
}
