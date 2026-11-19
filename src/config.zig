// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const toml = @import("toml");

const default_config_file = "/etc/nvuv/nvuv.toml";

const Range = struct {
    min: ?u32,
    max: u32,
};

pub const ClockConfig = union(enum) { locked: Range, reset: u8 };

pub const GpuConfig = struct {
    power_limit: ?u32,
    gpu_clocks: ?*ClockConfig,
    mem_clocks: ?*ClockConfig,
    gpu_offset: ?i32,
    mem_offset: ?i32,
};

pub const UserConfig = struct {
    gpu: []GpuConfig,
};

fn joinPath(buf: []u8, path: toml.FieldPath) []const u8 {
    if (path.len == 0) return "<root>";
    var w = std.Io.Writer.fixed(buf);
    for (path, 0..) |segment, i| {
        if (i > 0) w.writeByte('.') catch break;
        w.writeAll(segment) catch break;
    }
    return w.buffered();
}

fn logParseError(path: []const u8, err: anyerror, info: ?toml.ErrorInfo) void {
    var buf: [256]u8 = undefined;
    const einfo = info orelse {
        std.log.err("failed to parse config file '{s}': {s}", .{ path, @errorName(err) });
        return;
    };
    switch (einfo) {
        .parse => |pos| std.log.err(
            "failed to parse config file '{s}': {s} at line {d}, column {d}",
            .{ path, @errorName(err), pos.line, pos.pos },
        ),
        .unknown_fields => |u| {
            const table = joinPath(&buf, u.path);
            for (u.keys) |key| {
                std.log.err(
                    "failed to parse config file '{s}': unknown field '{s}' in '{s}'",
                    .{ path, key, table },
                );
            }
        },
        .struct_mapping => |field_path| {
            const field = joinPath(&buf, field_path);
            switch (err) {
                error.InvalidValueType => std.log.err(
                    "failed to parse config file '{s}': invalid value type for field '{s}'",
                    .{ path, field },
                ),
                error.MissingRequiredField => std.log.err(
                    "failed to parse config file '{s}': missing required field '{s}'",
                    .{ path, field },
                ),
                else => std.log.err(
                    "failed to parse config file '{s}': {s} for field '{s}'",
                    .{ path, @errorName(err), field },
                ),
            }
        },
    }
}

pub const Config = struct {
    parsed: toml.Parsed(UserConfig),

    pub fn load(io: std.Io, allocator: std.mem.Allocator, config_path: ?[]const u8) !Config {
        var parser = toml.Parser(UserConfig).init(allocator);
        parser.options.disallow_unknown_fields = true;
        defer parser.deinit();

        const path = config_path orelse default_config_file;
        std.log.debug("config file '{s}'", .{path});
        checkFile(io, path) catch |err| {
            std.log.err("failed to open config file '{s}': {s}", .{ path, @errorName(err) });
            return error.ConfigFileOpen;
        };

        const result = parser.parseFile(io, path) catch |err| {
            logParseError(path, err, parser.error_info);
            return error.ConfigFileParse;
        };

        return Config{
            .parsed = result,
        };
    }

    pub fn get(self: *const Config) UserConfig {
        return self.parsed.value;
    }

    pub fn print(self: *const Config) void {
        for (self.parsed.value.gpu, 0..) |gpu, idx| {
            std.debug.print("GPU{d}:\n{}\n", .{ idx, gpu });
        }
    }

    pub fn deinit(self: *const Config) void {
        self.parsed.deinit();
    }

    fn checkFile(io: std.Io, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, path, .{ .allow_directory = false });
        file.close(io);
    }
};
