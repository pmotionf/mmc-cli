pub const Cclink = @import("protocol/Cclink.zig");
pub const Ethercat = @import("protocol/Ethercat.zig");

pub const Config = union(enum) {
    cclink: struct {
        /// Channel used by the driver
        channel: Cclink.Channel,
        /// Station ID on the channel
        station_id: Cclink.Id,
        /// Number of axes used on the station
        axes: u2,
    },
    ethercat: struct {
        /// Station ID on the channel
        station_id: Cclink.Id,
        /// Number of axes used on the station
        axes: u2,
    },
};
