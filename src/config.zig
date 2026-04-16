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

pub const Config = struct {
    parsed: toml.Parsed(UserConfig),

    pub fn load(io: std.Io, allocator: std.mem.Allocator, config_path: ?[]const u8) !Config {
        var parser = toml.Parser(UserConfig).init(allocator);
        defer parser.deinit();

        const path = config_path orelse default_config_file;
        std.log.debug("config file '{s}'", .{path});
        checkFile(io, path) catch |err| {
            std.log.err("failed to open config file '{s}': {s}", .{ path, @errorName(err) });
            return error.ConfigFileOpen;
        };

        const result = parser.parseFile(io, path) catch |err| {
            std.log.err("failed to parse config file '{s}': {s}", .{ path, @errorName(err) });
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
