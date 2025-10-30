const std = @import("std");
const api = @import("mmc-api");
const zignet = @import("zignet");

const client = @import("../mmc_client.zig");
const command = @import("../../command.zig");

const CircularBufferAlloc = @import("../../circular_buffer.zig")
    .CircularBufferAlloc;

/// Logging configuration of mmc-client. Shall be initialized once the client
/// is connected to server. Must be deinitialized if the client is disconnected.
pub const Config = struct {
    /// Stores the log configuration of every lines that is passed by the track
    /// config, even for the line that is not going to be logged.
    lines: []Line,

    const Line = struct {
        /// Line ID, similar to track configuration.
        id: client.Line.Id,
        /// Tracking which drivers to be logged.
        drivers: []bool,
        /// Tracking which axes to be logged.
        axes: []bool,
    };

    /// Initialize the lines for storing the logging configuration.
    pub fn init(allocator: std.mem.Allocator, lines: []client.Line) !Config {
        var result: Config = undefined;
        result.lines = try allocator.alloc(Line, lines.len);
        errdefer allocator.free(result.lines);
        for (result.lines, lines) |*config_line, track_line| {
            config_line.id = track_line.id;
            config_line.axes = allocator.alloc(bool, track_line.axes);
            // TODO: Currently, there is no way to now the maximum number of
            // drivers in the system. It is best to caught if the axis or driver
            // is exceeding the actual number in the server. The following are a
            // way to get the maximum number of driver in a line. This shall be
            // addressed in the API 2.0.
        }
    }

    /// Add a new logging configurations. Overwriting configuration is allowed
    /// if the region is exactly the same as the one stored in the configuration
    /// before. Attempting to add a new configuration with overlapping region
    /// returns an error.
    pub fn add(new_line: Line, allocator: std.mem.Allocator) !void {
        // Check if the region is already used
        //
    }
};

var net_reader_buf: [4096]u8 = undefined;
var net_writer_buf: [4096]u8 = undefined;
var file_reader_buf: [4096]u8 = undefined;
var file_writer_buf: [4096]u8 = undefined;
// The following variables is initialized when the log runner is executed.
var net_reader: std.Io.Reader = undefined;
var net_writer: std.Io.Writer = undefined;
var file_reader: std.Io.Reader = undefined;
var file_writer: std.Io.Writer = undefined;
var socket: zignet.Socket = undefined;
