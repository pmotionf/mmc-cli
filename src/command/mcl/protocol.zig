pub const Cclink = @import("protocol/Cclink.zig");
pub const Ethercat = @import("protocol/Ethercat.zig");

pub const Config = union(enum) {
    cclink: Cclink.Config,
    ethercat: Ethercat.Config,
};
