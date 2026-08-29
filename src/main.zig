// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");

const cfg = @import("config.zig");
const cli = @import("cli.zig");
const Nvml = @import("nvml.zig").Nvml;

pub fn main(init: std.process.Init) !u8 {
    // NOTE: in dev use this allocator
    // const gpa = init.gpa;
    const gpa = init.arena.allocator();

    const parsed = cli.cli(init.minimal.args, init.io, gpa) catch |err|
        return if (err == error.ParseCaught) 1 else err;
    std.log.debug("cli parsed: {any}", .{parsed});

    if (parsed == .noop) {
        return 0;
    }

    const config = switch (parsed) {
        .showcfg, .applycfg => |opt| try cfg.Config.load(init.io, gpa, opt.path),
        else => null,
    };
    defer if (config) |conf| conf.deinit();

    if (parsed == .showcfg) {
        config.?.print();
        return 0;
    }

    var nvml = try Nvml.init(gpa);
    defer nvml.deinit();

    if (nvml.gpu_count == 0 and parsed != .info) {
        std.log.warn("no GPU found", .{});
        return 1;
    }
    const userconf = if (config) |conf| conf.get() else null;
    nvml.dispatch(parsed, userconf) catch |err|
        return switch (err) {
            error.InvalidGpuIndex,
            error.CommandError,
            error.NoConfigFound,
            error.EmptyConfig,
            error.InvalidPState,
            error.RootRequired,
            => 1,
        };
    return 0;
}
