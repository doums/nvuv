// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");

const cfg = @import("config.zig");
const cli = @import("cli.zig");
const Nvml = @import("nvml.zig").Nvml;

pub fn main(init: std.process.Init) !void {
    // NOTE: in dev use this allocator
    // const gpa = init.gpa;
    const gpa = init.arena.allocator();

    const parsed = try cli.cli(init.minimal.args, init.io, gpa);
    std.log.debug("cli parsed: {any}", .{parsed});

    if (parsed == .noop) {
        return;
    }

    const config = switch (parsed) {
        .showcfg, .applycfg => |opt| try cfg.Config.load(init.io, gpa, opt.path),
        else => null,
    };
    defer if (config) |conf| conf.deinit();

    if (parsed == .showcfg) {
        config.?.print();
        return;
    }

    var nvml = try Nvml.init(gpa);
    defer nvml.deinit();

    if (nvml.gpu_count == 0 and parsed != .info) {
        std.log.warn("no GPU found", .{});
        return;
    }
    const userconf = if (config) |conf| conf.get() else null;
    try nvml.dispatch(parsed, userconf);
}
