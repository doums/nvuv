// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const clap = @import("clap");

const bin_name = @import("buildmeta").name;
const bin_version = @import("buildmeta").version;

pub const Command = enum {
    gpu,
    gpun,
    ps, // by P-state gpu/mem clocks and offsets
    psn,
    get,
    set,
    reset,
    cfg,
    applycfg,
    info,
};

// for internal use, commands into parsed result mapping
pub const Op = enum {
    gpu,
    gpus,
    pstate,
    pstates,
    get,
    set,
    reset,
    showcfg,
    applycfg,
    info,
    noop,
};

pub const Parsed = union(Op) {
    gpu: struct {
        gpu: ?u16,
    },
    gpus,
    pstate: struct {
        gpu: ?u16,
        pstate: ?u16,
    },
    pstates: struct {
        gpu: ?u16,
    },
    get: struct {
        props: GetGpuProps,
        gpu: ?u16,
        pstate: ?u16,
    },
    set: struct {
        props: SetGpuProps,
        gpu: ?u16,
    },
    reset: struct {
        props: GetGpuProps,
        gpu: ?u16,
    },
    showcfg: ConfigOption,
    applycfg: ConfigOption,
    info,
    noop,
};

pub const ConfigOption = struct {
    path: ?[]const u8,
};

pub const GetGpuProps = struct {
    power_limit: ?bool = null,
    gpu_clock: ?bool = null,
    mem_clock: ?bool = null,
    gpu_clock_offset: ?bool = null,
    mem_clock_offset: ?bool = null,

    fn default() GetGpuProps {
        return GetGpuProps{
            .power_limit = true,
            .gpu_clock = true,
            .mem_clock = true,
            .gpu_clock_offset = true,
            .mem_clock_offset = true,
        };
    }
};

const Range = struct {
    min: ?u32,
    max: ?u32,
};

pub const SetGpuProps = struct {
    power_limit: ?u32 = null,
    gpu_clock: ?Range = null,
    mem_clock: ?Range = null,
    gpu_clock_offset: ?i32 = null,
    mem_clock_offset: ?i32 = null,
};

const main_parsers = .{
    .CMD = clap.parsers.enumeration(Command),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help
    \\-v, --version
    \\<CMD>
    \\
);

const main_help =
    \\CLI tool for undervolting and overclocking NVIDIA gpu
    \\
    \\Usage: nvuv [OPTIONS] [COMMAND]
    \\
    \\Commands:
    \\  gpu         Print gpu info
    \\  gpun        Print number of detected GPUs
    \\  ps          Print clocks and offsets by P-state
    \\  psn         Print supported P-states
    \\  get         Get gpu settings
    \\  set         Set gpu settings (root required)
    \\  reset       Reset gpu settings to default (root required)
    \\  cfg         Print parsed config file (debug)
    \\  applycfg    Apply settings from config file (root required)
    \\  info        Print driver, NVML version and detected GPUs
    \\
    \\Options:
    \\  -h, --help       Print help
    \\  -v, --version    Print version
    \\
;

const showcfg_help =
    \\Print parsed config file (debug)
    \\
    \\Usage: nvuv cfg [OPTIONS]
    \\
    \\Options:
    \\
;

const applycfg_help =
    \\Apply config settings (root required)
    \\
    \\Usage: nvuv applycfg [OPTIONS]
    \\
    \\Options:
    \\
;

const config_command_options =
    \\  -c, --config <FILE>   Path to config file (default: /etc/nvuv/nvuv.toml)
    \\  -h, --help            Print help
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
        report(diag, err, .{ .top_level = true });
        try printUsage(io, &main_params, null);
        return parseErrOut(err);
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
        .gpu => try gpu(io, gpa, &iter),
        .gpun => try gpun(io, gpa, &iter),
        .ps => try pstate(io, gpa, &iter),
        .psn => try pstaten(io, gpa, &iter),
        .get => try get(io, gpa, &iter),
        .set => try set(io, gpa, &iter),
        .reset => try reset(io, gpa, &iter),
        .cfg => try config_commands(.showcfg, io, gpa, &iter, showcfg_help),
        .applycfg => try config_commands(.applycfg, io, gpa, &iter, applycfg_help),
        .info => try info(io, gpa, &iter),
    };
}

fn get(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Get GPU settings
        \\
        \\Usage: nvuv get [OPTIONS] [PSTATE]
        \\
        \\Arguments:
        \\  [PSTATE]  Query specific P-state by index (0-based)
        \\
        \\Options:
        \\  -w, --power-limit   Print power limit
        \\  -g, --gpu-clock     Print gpu clocks (range only)
        \\  -m, --mem-clock     Print memory clocks (range only)
        \\  -G, --gpu-offset    Print gpu clock offsets
        \\  -M, --mem-offset    Print memory clock offsets
        \\  -i, --gpu-index <GPU>
        \\        Query a specific gpu by index (0-based)
        \\  -h, --help          Print help
        \\
    ;

    const options =
        \\  -w, --power-limit
        \\  -g, --gpu-clock
        \\  -m, --mem-clock
        \\  -G, --gpu-offset
        \\  -M, --mem-offset
        \\  -i, --gpu-index <GPU>
        \\  -h, --help
        \\  <PSTATE>
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .GPU = clap.parsers.int(u16, 10),
        .PSTATE = clap.parsers.int(u16, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "get");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print(help, .{});
        return .noop;
    }

    var props: GetGpuProps = .{};
    if (res.args.@"power-limit" != 0) props.power_limit = true;
    if (res.args.@"gpu-clock" != 0) props.gpu_clock = true;
    if (res.args.@"mem-clock" != 0) props.mem_clock = true;
    if (res.args.@"gpu-offset" != 0) props.gpu_clock_offset = true;
    if (res.args.@"mem-offset" != 0) props.mem_clock_offset = true;

    if (!hasFieldSet(props)) {
        props = GetGpuProps.default();
    }

    return .{ .get = .{
        .props = props,
        .gpu = res.args.@"gpu-index",
        .pstate = res.positionals[0],
    } };
}

fn set(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Set GPU settings (requires root)
        \\
        \\Usage: nvuv set [OPTIONS]
        \\
        \\Options:
        \\  -w, --power-limit <W>   Set power limit (W)
        \\  -g, --gpu-clock [MIN]..[MAX]
        \\        Set gpu locked clock (MHz) (default: lowest/highest supported)
        \\        Example: -g 200..2000, -g ..2000, -g 200..
        \\  -m, --mem-clock [MIN]..[MAX]
        \\        Set memory locked clock (MHz) (default: lowest/highest supported)
        \\        Example: -m 400..14000, -g ..14000, -g 400..
        \\  -G, --gpu-offset <MHz>  Set gpu clock offset (MHz) (negative values allowed)
        \\  -M, --mem-offset <MHz>  Set memory clock offset (MHz) (negative values allowed)
        \\  -i, --gpu-index <GPU>   Set specific gpu by index (0-based)
        \\  -h, --help              Print help
        \\
    ;

    const options =
        \\  -w, --power-limit <POWERLIMIT>
        \\  -g, --gpu-clock <GPUCLOCK>
        \\  -m, --mem-clock <MEMCLOCK>
        \\  -G, --gpu-offset <GPUOFFSET>
        \\  -M, --mem-offset <MEMOFFSET>
        \\  -i, --gpu-index <GPU>
        \\  -h, --help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .POWERLIMIT = clap.parsers.int(u32, 10),
        .GPUCLOCK = rangeParser,
        .MEMCLOCK = rangeParser,
        .GPUOFFSET = clap.parsers.int(i32, 10),
        .MEMOFFSET = clap.parsers.int(i32, 10),
        .GPU = clap.parsers.int(u16, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "set");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print(help, .{});
        return .noop;
    }
    var props: SetGpuProps = .{};
    if (res.args.@"power-limit") |pl| props.power_limit = pl;
    if (res.args.@"gpu-clock") |gc| props.gpu_clock = gc;
    if (res.args.@"mem-clock") |mc| props.mem_clock = mc;
    if (res.args.@"gpu-offset") |go| props.gpu_clock_offset = go;
    if (res.args.@"mem-offset") |mo| props.mem_clock_offset = mo;

    if (!hasFieldSet(props)) {
        std.log.err("no option given", .{});
        try printUsage(io, &params, "set");
        return error.ParseCaught;
    }

    return .{ .set = .{
        .props = props,
        .gpu = res.args.@"gpu-index",
    } };
}

fn reset(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Reset GPU settings to default (requires root).
        \\
        \\Usage: nvuv reset [OPTIONS]
        \\
        \\Options:
        \\
    ;

    const options =
        \\  -A, --all           Reset all properties
        \\  -w, --power-limit   Reset power limit
        \\  -g, --gpu-clock     Reset gpu locked clocks
        \\  -m, --mem-clock     Reset memory locked clocks
        \\  -G, --gpu-offset    Reset gpu clock offsets
        \\  -M, --mem-offset    Reset memory clock offsets
        \\  -i, --gpu-index <GPU>
        \\        Reset a specific gpu by index (0-based)
        \\  -h, --help          Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .GPU = clap.parsers.int(u16, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "reset");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}", .{ help, options });
        return .noop;
    }

    var props: GetGpuProps = .{};
    if (res.args.all != 0) {
        props = GetGpuProps.default();
    }
    if (res.args.@"power-limit" != 0) props.power_limit = true;
    if (res.args.@"gpu-clock" != 0) props.gpu_clock = true;
    if (res.args.@"mem-clock" != 0) props.mem_clock = true;
    if (res.args.@"gpu-offset" != 0) props.gpu_clock_offset = true;
    if (res.args.@"mem-offset" != 0) props.mem_clock_offset = true;

    if (!hasFieldSet(props)) {
        std.log.err("no option given", .{});
        try printUsage(io, &params, "reset");
        return error.ParseCaught;
    }

    return .{ .reset = .{
        .props = props,
        .gpu = res.args.@"gpu-index",
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
        report(diag, err, .{});
        try printUsage(io, &params, if (op == .showcfg) "cfg" else "applycfg");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}", .{ help, config_command_options });
        return .noop;
    }
    return @unionInit(Parsed, @tagName(op), .{
        .path = res.args.config,
    });
}

fn info(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Print driver, NVML version and detected GPUs
        \\
        \\Usage: nvuv info [OPTIONS]
        \\
        \\Options:
        \\
    ;

    const options =
        \\  -h, --help    Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "info");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}\n", .{ help, options });
        return .noop;
    }
    return .info;
}

fn gpu(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Print gpu info
        \\
        \\Usage: nvuv gpu [OPTIONS]
        \\
        \\Options:
        \\
    ;

    const options =
        \\  -i, --gpu-index <GPU>
        \\        Query a specific gpu by index (0-based)
        \\  -h, --help    Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);

    var diag = clap.Diagnostic{};
    const parsers = comptime .{
        .GPU = clap.parsers.int(u16, 10),
    };
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "gpu");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}", .{ help, options });
        return .noop;
    }
    return .{ .gpu = .{
        .gpu = res.args.@"gpu-index",
    } };
}

fn gpun(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Print the number of detected GPUs
        \\
        \\Usage: nvuv gpun [OPTIONS]
        \\
        \\Options:
        \\
    ;

    const options =
        \\  -h, --help    Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "gpun");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}", .{ help, options });
        return .noop;
    }
    return .gpus;
}

fn pstate(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Print clocks and offsets by P-state
        \\
        \\Usage: nvuv ps [OPTIONS] [PSTATE]
        \\
        \\Arguments:
        \\  [PSTATE]  Query specific P-state by index (0-based)
        \\
        \\Options:
        \\  -i, --gpu-index <GPU>
        \\        Query a specific gpu by index (0-based)
        \\  -h, --help    Print help
        \\
    ;

    const options =
        \\  -i, --gpu-index <GPU>
        \\        Query a specific gpu by index (0-based)
        \\  -h, --help    Print help
        \\  <PSTATE>
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);

    var diag = clap.Diagnostic{};
    const parsers = comptime .{
        .PSTATE = clap.parsers.int(u16, 10),
        .GPU = clap.parsers.int(u16, 10),
    };
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "ps");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print(help, .{});
        return .noop;
    }
    return .{ .pstate = .{
        .pstate = res.positionals[0],
        .gpu = res.args.@"gpu-index",
    } };
}

fn pstaten(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Print supported P-states
        \\
        \\Usage: nvuv psn [OPTIONS]
        \\
        \\Options:
        \\
    ;

    const options =
        \\  -i, --gpu-index <GPU>
        \\        Query a specific gpu by index (0-based)
        \\  -h, --help    Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);

    var diag = clap.Diagnostic{};
    const parsers = comptime .{
        .GPU = clap.parsers.int(u16, 10),
    };
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err, .{});
        try printUsage(io, &params, "psn");
        return parseErrOut(err);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}", .{ help, options });
        return .noop;
    }
    return .{ .pstates = .{
        .gpu = res.args.@"gpu-index",
    } };
}

fn printUsage(io: std.Io, params: anytype, command: ?[]const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    const w = &writer.interface;
    if (command) |cmd| {
        try w.print("→ {s} {s} ", .{ bin_name, cmd });
    } else {
        try w.print("→ {s} ", .{bin_name});
    }
    try clap.usage(w, clap.Help, params);
    try w.writeByte('\n');
    try w.flush();
}

// based on https://hejsil.github.io/zig-clap/#test.Diagnostic.report
fn report(
    diag: clap.Diagnostic,
    err: anyerror,
    comptime opt: struct { top_level: bool = false },
) void {
    var longest = diag.name.longest();
    if (longest.kind == .positional)
        longest.name = diag.arg;

    switch (err) {
        error.DoesntTakeValue => std.log.err(
            "the option '{s}{s}' does not take a value",
            .{ longest.kind.prefix(), longest.name },
        ),
        error.MissingValue => std.log.err(
            "the option '{s}{s}' requires a value",
            .{ longest.kind.prefix(), longest.name },
        ),
        error.InvalidArgument => switch (longest.kind) {
            .positional => std.log.err(
                "invalid argument '{s}'",
                .{longest.name},
            ),
            .long, .short => std.log.err(
                "invalid option '{s}{s}'",
                .{ longest.kind.prefix(), longest.name },
            ),
        },
        error.NameNotPartOfEnum => if (opt.top_level) {
            std.log.err("invalid command", .{});
        } else {
            std.log.err("invalid option value", .{});
        },
        // int parser errors
        error.InvalidCharacter,
        error.Overflow,
        => std.log.err("invalid numeric value", .{}),
        error.InvalidRangeValue => std.log.err("invalid range value", .{}),
        else => std.log.err("arguments parsing failed: {s}", .{@errorName(err)}),
    }
}

fn rangeParser(in: []const u8) (error{InvalidRangeValue})!Range {
    const delim = std.mem.find(u8, in, "..") orelse return error.InvalidRangeValue;
    const min_s = in[0..delim];
    const max_s = in[delim + 2 ..];
    if (min_s.len == 0 and max_s.len == 0) return error.InvalidRangeValue;

    const min: ?u32 = if (min_s.len == 0) null else std.fmt.parseUnsigned(u32, min_s, 10) catch return error.InvalidRangeValue;
    const max: ?u32 = if (max_s.len == 0) null else std.fmt.parseUnsigned(u32, max_s, 10) catch return error.InvalidRangeValue;
    if (min) |mi| if (max) |ma| {
        if (mi > ma) return error.InvalidRangeValue;
    };

    return .{ .min = min, .max = max };
}

test "rangeParser" {
    try std.testing.expectEqual(Range{ .min = null, .max = 123 }, rangeParser("..123"));
    try std.testing.expectEqual(Range{ .min = 123, .max = null }, rangeParser("123.."));
    try std.testing.expectEqual(Range{ .min = 123, .max = 123 }, rangeParser("123..123"));
    try std.testing.expectEqual(Range{ .min = 1, .max = 2 }, rangeParser("1..2"));
    try std.testing.expectError(error.InvalidRangeValue, rangeParser("2..1"));
    try std.testing.expectError(error.InvalidRangeValue, rangeParser(".."));
    try std.testing.expectError(error.InvalidRangeValue, rangeParser("123"));
    try std.testing.expectError(error.InvalidRangeValue, rangeParser("abc"));
}

/// Merge and map user caught parse errors so main can filter them
fn parseErrOut(
    err: anyerror,
) anyerror {
    return switch (err) {
        error.DoesntTakeValue,
        error.MissingValue,
        error.InvalidArgument,
        error.NameNotPartOfEnum,
        // int parser errors
        error.InvalidCharacter,
        error.Overflow,
        error.InvalidRangeValue,
        => error.ParseCaught,
        else => err,
    };
}

fn hasFieldSet(self: anytype) bool {
    const T = @TypeOf(self);
    const tinfo = @typeInfo(T).@"struct";
    inline for (tinfo.field_names, tinfo.field_types) |name, ty| {
        if (@typeInfo(ty) != .optional)
            @compileError("hasFieldSet: field '" ++ name ++ "' of " ++ @typeName(T) ++ " not optional");
        if (@field(self, name) != null) return true;
    }
    return false;
}
