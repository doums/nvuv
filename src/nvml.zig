// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const c = @import("c.zig").c;
const nvmlCheck = @import("c.zig").nvmlCheck;
const Gpu = @import("gpu.zig").Gpu;
const Parsed = @import("cli.zig").Parsed;
const UserConfig = @import("config.zig").UserConfig;

const driver_buf_size = c.NVML_SYSTEM_DRIVER_VERSION_BUFFER_SIZE;
const nvml_buf_size = c.NVML_SYSTEM_NVML_VERSION_BUFFER_SIZE;

pub const Nvml = struct {
    allocator: std.mem.Allocator,
    driver_version: []u8, // owned memory
    nvml_version: []u8, // owned memory
    gpu_count: u32,
    gpus: []Gpu,

    pub fn init(gpa: std.mem.Allocator) !Nvml {
        try nvmlCheck(c.nvmlInit());

        var driver_version: [driver_buf_size:0]u8 = undefined;
        var nvml_version: [nvml_buf_size:0]u8 = undefined;
        // zig's usize = 64bits, nvml APIs expect c_uint = 32bits
        // so let's cast
        try nvmlCheck(c.nvmlSystemGetDriverVersion(&driver_version, @intCast(driver_version.len)));
        try nvmlCheck(c.nvmlSystemGetNVMLVersion(&nvml_version, @intCast(nvml_version.len)));
        var device_count: c_uint = 0;
        try nvmlCheck(c.nvmlDeviceGetCount(&device_count));

        // memory copy C sliced buffers, as in gpu.zig init
        const owned_nvml_version = try gpa.dupe(u8, std.mem.sliceTo(&nvml_version, 0));
        const owned_driver_version = try gpa.dupe(u8, std.mem.sliceTo(&driver_version, 0));

        std.log.debug("NVML version: {s}", .{owned_nvml_version});
        std.log.debug("driver version: {s}", .{owned_driver_version});
        std.log.debug("GPUs number: {d}", .{device_count});

        var arr: std.ArrayList(Gpu) = .empty;
        errdefer {
            for (arr.items) |*g| g.deinit(gpa);
            arr.deinit(gpa);
            nvmlCheck(c.nvmlShutdown()) catch {};
            gpa.free(owned_nvml_version);
            gpa.free(owned_driver_version);
        }

        for (0..device_count) |index| {
            const gpu = try Gpu.from_index(index, gpa);
            try arr.append(gpa, gpu);
        }
        const gpus = try arr.toOwnedSlice(gpa);

        return Nvml{
            .allocator = gpa,
            .driver_version = owned_driver_version,
            .nvml_version = owned_nvml_version,
            .gpu_count = device_count,
            .gpus = gpus,
        };
    }

    pub fn dispatch(self: *const Nvml, parsed: Parsed, config: ?UserConfig) !void {
        switch (parsed) {
            .query => |handler| {
                try handler.run(self.gpus);
            },
            .set => |handler| {
                try handler.run(self.gpus);
            },
            .reset => |handler| {
                try handler.run(self.gpus);
            },
            .info => {
                std.debug.print("NVIDIA driver: {s}\n", .{self.driver_version});
                std.debug.print("NVML version: {s}\n", .{self.nvml_version});
                for (self.gpus) |gpu| {
                    std.debug.print("GPU{d}: {s}\n", .{ gpu.index, gpu.name });
                }
            },
            .applycfg => {
                const conf = config orelse {
                    std.log.warn("no config to apply", .{});
                    return error.NoConfigFound;
                };
                if (conf.gpu.len == 0) {
                    std.log.warn("config has no GPU entries", .{});
                    return error.EmptyConfig;
                }
                for (conf.gpu, 0..) |gpu_cfg, idx| {
                    if (idx >= self.gpus.len) {
                        std.log.warn("invalid GPU in config at index {d} (0-based), skipping…", .{idx});
                        continue;
                    }
                    const gpu = &self.gpus[idx];
                    gpu.applyConfig(gpu_cfg);
                }
            },
            else => unreachable,
        }
    }

    pub fn deinit(self: *Nvml) void {
        for (self.gpus) |*g| g.deinit(self.allocator);
        self.allocator.free(self.gpus);
        self.allocator.free(self.nvml_version);
        self.allocator.free(self.driver_version);
        nvmlCheck(c.nvmlShutdown()) catch {};
    }
};
