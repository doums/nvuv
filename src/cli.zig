// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const clap = @import("clap");

const bin_name = @import("buildmeta").name;
const bin_version = @import("buildmeta").version;

const Query = @import("query.zig").Query;
const QueryHandler = @import("query.zig").QueryHandler;
const SetHandler = @import("query.zig").SetHandler;
const ResetHandler = @import("query.zig").ResetHandler;
const PropValue = @import("query.zig").PropValue;

pub const Command = enum {
    get,
    set,
    reset,
    cfg,
    applycfg,
};

// for internal use, mapped from SubCommands
pub const Op = enum {
    query,
    set,
    reset,
    showcfg,
    applycfg,
    noop,
};

pub const Parsed = union(Op) {
    query: QueryHandler,
    set: SetHandler,
    reset: ResetHandler,
    showcfg: ConfigOption,
    applycfg: ConfigOption,
    noop,
};

pub const ConfigOption = struct {
    path: ?[]const u8,
};

pub const CliQueryProperty = enum {
    gpu, // all info about a GPU
    gn,
    gpun, // GPUs number
    driver, // NVIDIA driver version
    ps, // supported P-states list
    pstates,
    psc, // GPU/MEM clocks and offsets
    pstateclk,
    w, // power limit - current, min/max
    pl,
    gc, // gpu clock - min/max only
    mc, // memory clock - min/max only
    go, // gpu clock offset - current, min/max
    mo, // memory clock offset - current, min/max

    fn toQuery(self: CliQueryProperty) Query {
        return switch (self) {
            .gpu => .gpu,
            .gn, .gpun => .gpu_num,
            .driver => .driver,
            .ps, .pstates => .pstates,
            .psc, .pstateclk => .pstate_clock,
            .w, .pl => .power_limit,
            .gc => .gpu_clock,
            .mc => .mem_clock,
            .go => .gpu_clock_offset,
            .mo => .mem_clock_offset,
        };
    }
};

pub const CliSetProperty = enum {
    w, // power limit
    pl,
    gl, // gpu locked clock
    gc,
    ml, // memory locked clock
    mc,
    go, // gpu clock offset
    mo, // memory clock offset

    fn toQuery(self: CliSetProperty) Query {
        return switch (self) {
            .w, .pl => .power_limit,
            .gl, .gc => .gpu_clock,
            .ml, .mc => .mem_clock,
            .go => .gpu_clock_offset,
            .mo => .mem_clock_offset,
        };
    }
};

const main_parsers = .{
    .command = clap.parsers.enumeration(Command),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help           Print help
    \\-v, --version        Print version
    \\<command>
    \\
);

const main_help =
    \\CLI tool for undervolting NVIDIA gpu
    \\
    \\Usage: nvuv [OPTIONS] [COMMAND]
    \\
    \\Commands:
    \\  get         Query gpu settings
    \\  set         Set gpu settings (root required)
    \\  reset       Reset gpu settings to default (root required)
    \\  cfg         Print config file
    \\  applycfg    Apply settings from config file (root required)
    \\
    \\Options:
    \\  -h, --help       Print help
    \\  -v, --version    Print version
    \\
;

const showcfg_help =
    \\Print config file
    \\
    \\Usage: nvuv cfg [OPTIONS]
    \\
    \\Options:
;

const applycfg_help =
    \\Apply config settings (root required)
    \\
    \\Usage: nvuv applycfg [OPTIONS]
    \\
    \\Options:
;

const config_command_options =
    \\  -h, --help             Print help
    \\  -c, --config <FILE>    Path to config file (default: /etc/nvuv/nvuv.toml)
    \\
;

const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn cli(args: std.process.Args, io: std.Io, gpa: std.mem.Allocator) !Parsed {
    var iter = try args.iterateAllocator(gpa);
    defer iter.deinit();

    // skip program name
    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        report(diag, err);
        std.debug.print("Usage: {s} ", .{bin_name});
        try printUsage(io, &main_params, null);
        std.debug.print("\n", .{});
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print(main_help, .{});
        return .noop;
    }
    if (res.args.version != 0) {
        std.debug.print("{s} {s}\n", .{ bin_name, bin_version });
        return .noop;
    }

    const command = res.positionals[0] orelse {
        std.debug.print(main_help, .{});
        return .noop;
    };
    return switch (command) {
        .get => try get(io, gpa, &iter),
        .set => try set(io, gpa, &iter),
        .reset => try reset(io, gpa, &iter),
        .cfg => try config_commands(.showcfg, io, gpa, &iter, showcfg_help),
        .applycfg => try config_commands(.applycfg, io, gpa, &iter, applycfg_help),
    };
}

fn get(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Query GPU settings
        \\
        \\Usage: nvuv get [OPTIONS] <QUERY> [PSTATE]
        \\
        \\Arguments:
        \\  <QUERY>   Possible values:
        \\    gpu               Print gpu info
        \\    gn, gpun          Print the number of gpus present on the system
        \\    driver            Print NVIDIA driver version
        \\    ps, pstates       Print supported P-states list
        \\    psc, pstateclk    Print all P-states clocks and offsets
        \\    w, pl             Print power limit
        \\    gc                Print gpu clocks (range only)
        \\    mc                Print memory clocks (range only)
        \\    go                Print gpu clock offsets
        \\    mo                Print memory clock offsets
        \\  [PSTATE]  Query specific P-state by index (0-based)
        \\
        \\Options:
        \\  -h, --help         Print help
        \\  -g, --gpu <GPU>    Query specific gpu by index (0-based)
        \\
    ;

    const options =
        \\  -h, --help         Print help
        \\  -g, --gpu <GPU>    Query specific gpu by index (0-based)
        \\  <QUERY>
        \\  <PSTATE>
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .GPU = clap.parsers.int(u16, 10),
        .QUERY = clap.parsers.enumeration(CliQueryProperty),
        .PSTATE = clap.parsers.int(u16, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "get");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n", .{help});
        return .noop;
    }
    if (res.positionals[0] == null) {
        std.log.err("Missing argument: QUERY", .{});
        try printUsage(io, &params, "get");
        return error.MissingArgument;
    }
    return .{ .query = .{
        .query = res.positionals[0].?.toQuery(),
        .gpu = res.args.gpu,
        .pstate = res.positionals[1],
    } };
}

fn set(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Set GPU settings (requires root)
        \\
        \\Usage: nvuv set [OPTIONS] <PROPERTY> <VALUE> [MINVAL]
        \\
        \\Arguments:
        \\  <PROPERTY>  Possible values:
        \\    w, pl         Set power limit (W)
        \\    gl, gc        Set gpu locked clock (MHz)
        \\    ml, mc        Set memory locked clock (MHz)
        \\    go            Set gpu clock offset (MHz)
        \\    mo            Set memory clock offset (MHz)
        \\  <VALUE>     Property value, W or MHz
        \\              Max clock for locked clocks
        \\  [MINVAL]    Min clock for locked clocks, if not provided
        \\              the min clock will be set to the lowest supported one
        \\
        \\Options:
        \\  -h, --help         Print help
        \\  -g, --gpu <GPU>    Set specific gpu by index (0-based)
        \\
    ;

    const options =
        \\  -h, --help         Print help
        \\  -g, --gpu <GPU>    Set specific gpu by index (0-based)
        \\  <PROPERTY>
        \\  <VALUE>
        \\  <MINVAL>
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .GPU = clap.parsers.int(u16, 10),
        .PROPERTY = clap.parsers.enumeration(CliSetProperty),
        .VALUE = intParser, // custom parser
        .MINVAL = clap.parsers.int(u32, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "set");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n", .{help});
        return .noop;
    }
    if (res.positionals[0] == null) {
        std.log.err("Missing argument: PROPERTY", .{});
        try printUsage(io, &params, "set");
        return error.MissingArgument;
    }
    if (res.positionals[1] == null) {
        std.log.err("Missing argument: VALUE", .{});
        try printUsage(io, &params, "set");
        return error.MissingArgument;
    }
    const property: Query = res.positionals[0].?.toQuery();
    var value: PropValue = res.positionals[1].?;
    // enforce that the input value for power limit and locked
    // clocks are uint, clock offsets are int
    switch (property) {
        .power_limit, .gpu_clock, .mem_clock => {
            if (value == .int) {
                std.log.err("Value for '{s}' must be a positive integer, got {d}", .{ @tagName(property), value.int });
                try printUsage(io, &params, "set");
                return error.InvalidArgument;
            }
        },
        .gpu_clock_offset, .mem_clock_offset => {
            // in case of positive offset was parsed as uint,
            // we must cast to int
            if (value == .uint) {
                const i_val = std.math.cast(i32, value.uint) orelse {
                    std.log.err("Value for '{s}' is out of range: {d}", .{ @tagName(property), value.uint });
                    return error.InvalidArgument;
                };
                value = .{ .int = i_val };
            }
        },
        else => unreachable,
    }
    // now the value is guaranteed to be of the correct type for
    // the property: power limit and locked clocks are uint, clock offsets are int
    return .{ .set = .{
        .property = property,
        .value = value,
        .minval = res.positionals[2],
        .gpu = res.args.gpu,
    } };
}

fn reset(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Reset GPU settings to default (requires root)
        \\
        \\Usage: nvuv reset [OPTIONS] <PROPERTY>
        \\
        \\Arguments:
        \\  <PROPERTY>  Possible values:
        \\    w, pl         Reset power limit
        \\    gl, gc        Reset gpu locked clock
        \\    ml, mc        Reset memory locked clock
        \\    go            Reset gpu clock offset
        \\    mo            Reset memory clock offset
        \\
        \\Options:
        \\  -h, --help         Print help
        \\  -g, --gpu <GPU>    Reset on specific gpu by index (0-based)
        \\
    ;

    const options =
        \\  -h, --help         Print help
        \\  -g, --gpu <GPU>    Reset on specific gpu by index (0-based)
        \\  <PROPERTY>
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .PROPERTY = clap.parsers.enumeration(CliSetProperty),
        .GPU = clap.parsers.int(u16, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "reset");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n", .{help});
        return .noop;
    }
    if (res.positionals[0] == null) {
        std.log.err("Missing argument: PROPERTY", .{});
        try printUsage(io, &params, "reset");
        return error.MissingArgument;
    }
    const property: Query = res.positionals[0].?.toQuery();

    return .{ .reset = .{
        .property = property,
        .gpu = res.args.gpu,
    } };
}

fn config_commands(
    comptime op: Op,
    io: std.Io,
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
    help: []const u8,
) !Parsed {
    const params = comptime clap.parseParamsComptime(config_command_options);
    const parsers = comptime .{
        .FILE = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, if (op == .showcfg) "cfg" else "applycfg");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n{s}\n", .{ help, config_command_options });
        return .noop;
    }
    return @unionInit(Parsed, @tagName(op), .{
        .path = res.args.config,
    });
}

fn printUsage(io: std.Io, params: anytype, subcmd: ?[]const u8) !void {
    if (subcmd) |cmd| {
        std.debug.print("Usage: {s} {s} ", .{ bin_name, cmd });
    } else {
        std.debug.print("Usage: {s} ", .{bin_name});
    }
    try clap.usageToFile(io, .stdout(), clap.Help, params);
    std.debug.print("\n", .{});
}

// based on https://hejsil.github.io/zig-clap/#test.Diagnostic.report
fn report(diag: clap.Diagnostic, err: anyerror) void {
    var longest = diag.name.longest();
    if (longest.kind == .positional)
        longest.name = diag.arg;

    switch (err) {
        error.DoesntTakeValue => std.log.err(
            "The argument '{s}{s}' does not take a value",
            .{ longest.kind.prefix(), longest.name },
        ),
        error.MissingValue => std.log.err(
            "The argument '{s}{s}' requires a value but none was supplied",
            .{ longest.kind.prefix(), longest.name },
        ),
        error.InvalidArgument => std.log.err(
            "Invalid argument '{s}{s}'",
            .{ longest.kind.prefix(), longest.name },
        ),
        else => std.log.err("Error while parsing arguments: {s}", .{@errorName(err)}),
    }
}

fn intParser(in: []const u8) std.fmt.ParseIntError!PropValue {
    if (std.fmt.parseUnsigned(u32, in, 10)) |v| {
        return .{ .uint = v };
    } else |_| {
        return .{ .int = try std.fmt.parseInt(i32, in, 10) };
    }
}

test "intParser" {
    try std.testing.expectEqual(PropValue{ .uint = 42 }, intParser("42"));
    try std.testing.expectEqual(PropValue{ .int = -42 }, intParser("-42"));
    try std.testing.expectError(std.fmt.ParseIntError.InvalidCharacter, intParser("0.42"));
    try std.testing.expectError(std.fmt.ParseIntError.InvalidCharacter, intParser("abc"));
}
