// Code generated by protoc-gen-zig
///! package mmc
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const fd = protobuf.fd;
const ManagedStruct = protobuf.ManagedStruct;

pub const GetRegister = struct {
    line_idx: i32 = 0,
    axis_idx: i32 = 0,

    pub const _desc_table = .{
        .line_idx = fd(1, .{ .Varint = .Simple }),
        .axis_idx = fd(2, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const GetStatus = struct {
    kind: Status = @enumFromInt(0),
    line_idx: i32 = 0,
    axis_idx: ?i32 = null,
    carrier_id: ?i32 = null,

    pub const _desc_table = .{
        .kind = fd(1, .{ .Varint = .Simple }),
        .line_idx = fd(2, .{ .Varint = .Simple }),
        .axis_idx = fd(3, .{ .Varint = .Simple }),
        .carrier_id = fd(4, .{ .Varint = .Simple }),
    };

    pub const Status = enum(i32) {
        StatusUnspecified = 0,
        Hall = 1,
        Carrier = 2,
        Command = 3,
        _,
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const NoParam = struct {
    pub const _desc_table = .{};

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const ClearErrorsAndCarrier = struct {
    line_id: i32 = 0,
    axis_id: i32 = 0,

    pub const _desc_table = .{
        .line_id = fd(1, .{ .Varint = .Simple }),
        .axis_id = fd(2, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const SetCommand = struct {
    command_code: CommandCode = @enumFromInt(0),
    line_idx: i32 = 0,
    axis_idx: i32 = 0,
    carrier_id: ?i32 = null,
    location_distance: ?f32 = null,
    speed: ?i32 = null,
    acceleration: ?i32 = null,
    link_axis: ?Direction = null,
    use_sensor: ?Direction = null,

    pub const _desc_table = .{
        .command_code = fd(1, .{ .Varint = .Simple }),
        .line_idx = fd(2, .{ .Varint = .Simple }),
        .axis_idx = fd(3, .{ .Varint = .Simple }),
        .carrier_id = fd(4, .{ .Varint = .Simple }),
        .location_distance = fd(5, .{ .FixedInt = .I32 }),
        .speed = fd(6, .{ .Varint = .Simple }),
        .acceleration = fd(7, .{ .Varint = .Simple }),
        .link_axis = fd(8, .{ .Varint = .Simple }),
        .use_sensor = fd(9, .{ .Varint = .Simple }),
    };

    pub const CommandCode = enum(i32) {
        None = 0,
        SetLineZero = 1,
        PositionMoveCarrierAxis = 18,
        PositionMoveCarrierLocation = 19,
        PositionMoveCarrierDistance = 20,
        SpeedMoveCarrierAxis = 21,
        SpeedMoveCarrierLocation = 22,
        SpeedMoveCarrierDistance = 23,
        IsolateForward = 24,
        IsolateBackward = 25,
        Calibration = 26,
        SetCarrierIdAtAxis = 29,
        PushForward = 30,
        PushBackward = 31,
        PullForward = 32,
        PullBackward = 33,
        PushTransitionForward = 34,
        PushTransitionBackward = 35,
        PullTransitionAxisForward = 36,
        PullTransitionAxisBackward = 37,
        PullTransitionLocationForward = 38,
        PullTransitionLocationBackward = 39,
        _,
    };

    pub const Direction = enum(i32) {
        NoDirection = 0,
        Backward = 1,
        Forward = 2,
        _,
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const AutoInitialize = struct {
    line_id: ?i32 = null,

    pub const _desc_table = .{
        .line_id = fd(1, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const SendCommand = struct {
    kind: ServerCommand = @enumFromInt(0),
    parameter: ?parameter_union,

    pub const _parameter_case = enum {
        get_x,
        get_y,
        get_wr,
        get_ww,
        get_status,
        get_version,
        clear_errors,
        clear_carrier_info,
        reset_mcl,
        release_axis_servo,
        set_command,
        stop_pull_carrier,
        auto_initialize,
    };
    pub const parameter_union = union(_parameter_case) {
        get_x: GetRegister,
        get_y: GetRegister,
        get_wr: GetRegister,
        get_ww: GetRegister,
        get_status: GetStatus,
        get_version: NoParam,
        clear_errors: ClearErrorsAndCarrier,
        clear_carrier_info: ClearErrorsAndCarrier,
        reset_mcl: NoParam,
        release_axis_servo: GetRegister,
        set_command: SetCommand,
        stop_pull_carrier: GetRegister,
        auto_initialize: AutoInitialize,
        pub const _union_desc = .{
            .get_x = fd(2, .{ .SubMessage = {} }),
            .get_y = fd(3, .{ .SubMessage = {} }),
            .get_wr = fd(4, .{ .SubMessage = {} }),
            .get_ww = fd(5, .{ .SubMessage = {} }),
            .get_status = fd(6, .{ .SubMessage = {} }),
            .get_version = fd(7, .{ .SubMessage = {} }),
            .clear_errors = fd(9, .{ .SubMessage = {} }),
            .clear_carrier_info = fd(10, .{ .SubMessage = {} }),
            .reset_mcl = fd(11, .{ .SubMessage = {} }),
            .release_axis_servo = fd(12, .{ .SubMessage = {} }),
            .set_command = fd(13, .{ .SubMessage = {} }),
            .stop_pull_carrier = fd(14, .{ .SubMessage = {} }),
            .auto_initialize = fd(16, .{ .SubMessage = {} }),
        };
    };

    pub const _desc_table = .{
        .kind = fd(1, .{ .Varint = .Simple }),
        .parameter = fd(null, .{ .OneOf = parameter_union }),
    };

    pub const ServerCommand = enum(i32) {
        ServerCommandUnspecified = 0,
        GetX = 1,
        GetY = 2,
        GetWr = 3,
        GetWw = 4,
        GetStatus = 5,
        GetVersion = 6,
        ClearErrors = 8,
        ClearCarrierInfo = 9,
        ResetMCL = 10,
        ReleaseAxisServo = 11,
        SetCommand = 12,
        StopPullCarrier = 13,
        AutoInitialize = 15,
        _,
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const LineConfig = struct {
    lines: ArrayList(LineConfiguration),
    line_names: ArrayList(ManagedString),

    pub const _desc_table = .{
        .lines = fd(1, .{ .List = .{ .SubMessage = {} } }),
        .line_names = fd(2, .{ .List = .String }),
    };

    pub const LineConfiguration = struct {
        axes: i32 = 0,
        ranges: ArrayList(Range),

        pub const _desc_table = .{
            .axes = fd(1, .{ .Varint = .Simple }),
            .ranges = fd(2, .{ .List = .{ .SubMessage = {} } }),
        };

        pub const Range = struct {
            channel: Channel = @enumFromInt(0),
            start: i32 = 0,
            end: i32 = 0,

            pub const _desc_table = .{
                .channel = fd(1, .{ .Varint = .Simple }),
                .start = fd(2, .{ .Varint = .Simple }),
                .end = fd(3, .{ .Varint = .Simple }),
            };

            pub const Channel = enum(i32) {
                CHANNEL_UNSPECIFIED = 0,
                cc_link_1slot = 1,
                cc_link_2slot = 2,
                cc_link_3slot = 3,
                cc_link_4slot = 4,
                _,
            };

            pub usingnamespace protobuf.MessageMixins(@This());
        };

        pub usingnamespace protobuf.MessageMixins(@This());
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const ServerVersion = struct {
    major: i32 = 0,
    minor: i32 = 0,
    patch: i32 = 0,

    pub const _desc_table = .{
        .major = fd(1, .{ .Varint = .Simple }),
        .minor = fd(2, .{ .Varint = .Simple }),
        .patch = fd(3, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const HallStatus = struct {
    configured: bool = false,
    front: bool = false,
    back: bool = false,

    pub const _desc_table = .{
        .configured = fd(1, .{ .Varint = .Simple }),
        .front = fd(2, .{ .Varint = .Simple }),
        .back = fd(3, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const CarrierStatus = struct {
    id: i32 = 0,
    axis_idx: ?AxisIndices = null,
    location: f32 = 0,
    state: CarrierState = @enumFromInt(0),

    pub const _desc_table = .{
        .id = fd(1, .{ .Varint = .Simple }),
        .axis_idx = fd(2, .{ .SubMessage = {} }),
        .location = fd(3, .{ .FixedInt = .I32 }),
        .state = fd(4, .{ .Varint = .Simple }),
    };

    pub const CarrierState = enum(i32) {
        None = 0,
        WarmupProgressing = 1,
        WarmupCompleted = 2,
        PosMoveProgressing = 4,
        PosMoveCompleted = 5,
        SpdMoveProgressing = 6,
        SpdMoveCompleted = 7,
        Auxiliary = 8,
        AuxiliaryCompleted = 9,
        ForwardCalibrationProgressing = 10,
        ForwardCalibrationCompleted = 11,
        BackwardCalibrationProgressing = 12,
        BackwardCalibrationCompleted = 13,
        ForwardIsolationProgressing = 16,
        ForwardIsolationCompleted = 17,
        BackwardIsolationProgressing = 18,
        BackwardIsolationCompleted = 19,
        ForwardRestartProgressing = 20,
        ForwardRestartCompleted = 21,
        BackwardRestartProgressing = 22,
        BackwardRestartCompleted = 23,
        PullForward = 25,
        PullForwardCompleted = 26,
        PullBackward = 27,
        PullBackwardCompleted = 28,
        Push = 29,
        PushCompleted = 30,
        Overcurrent = 31,
        _,
    };

    pub const AxisIndices = struct {
        main_axis: i32 = 0,
        aux_axis: i32 = 0,

        pub const _desc_table = .{
            .main_axis = fd(1, .{ .Varint = .Simple }),
            .aux_axis = fd(2, .{ .Varint = .Simple }),
        };

        pub usingnamespace protobuf.MessageMixins(@This());
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const CommandStatus = struct {
    received: bool = false,
    response: CommandResponse = @enumFromInt(0),

    pub const _desc_table = .{
        .received = fd(1, .{ .Varint = .Simple }),
        .response = fd(2, .{ .Varint = .Simple }),
    };

    pub const CommandResponse = enum(i32) {
        NoError = 0,
        InvalidCommand = 1,
        CarrierNotFound = 2,
        HomingFailed = 3,
        InvalidParameter = 4,
        InvalidSystemState = 5,
        CarrierAlreadyExists = 6,
        InvalidAxis = 7,
        _,
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
