// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const Gpu = @import("gpu.zig").Gpu;

pub const Query = enum {
    gpu, // all info about a GPU
    gpu_num, // GPUs number
    driver, // NVIDIA driver version
    pstates, // supported P-states list
    pstate_clock, // GPU/MEM clocks and offsets
    power_limit,
    gpu_clock,
    mem_clock,
    gpu_clock_offset,
    mem_clock_offset,
};

pub const QueryHandler = struct {
    query: Query,
    gpu: ?u16,
    pstate: ?u16,

    pub fn run(self: QueryHandler, gpus: []const Gpu, driver: []const u8) !void {
        if (gpus.len == 0) unreachable;

        const index = self.gpu orelse 0;
        if (index >= gpus.len) {
            std.log.err("invalid GPU index {d} (0-based)", .{index});
            return error.InvalidGpuIndex;
        }
        const gpu = &gpus[index];

        switch (self.query) {
            .gpu => gpus[index].print(),
            .gpu_num => std.debug.print("GPU count: {d}\n", .{gpus.len}),
            .driver => std.debug.print("NVIDIA driver: {s}\n", .{driver}),
            .pstates => gpus[index].printSupportedPStates(),
            .pstate_clock => try gpus[index].printPStateClocks(self.pstate),
            .power_limit => gpu.printPowerLimit(),
            .gpu_clock => try gpu.printClock(.gpu, self.pstate),
            .mem_clock => try gpu.printClock(.mem, self.pstate),
            .gpu_clock_offset => try gpu.printClockOffset(.gpu, self.pstate),
            .mem_clock_offset => try gpu.printClockOffset(.mem, self.pstate),
        }
    }
};

pub const PropValue = union(enum) {
    int: i32,
    uint: u32,
};

pub const SetHandler = struct {
    property: Query,
    value: PropValue,
    minval: ?u32,
    gpu: ?u16,

    pub fn run(self: SetHandler, gpus: []Gpu) !void {
        if (gpus.len == 0) unreachable;

        const index = self.gpu orelse 0;
        if (index >= gpus.len) {
            std.log.err("invalid GPU index {d} (0-based)", .{index});
            return error.InvalidGpuIndex;
        }
        const gpu = &gpus[index];

        // redundant check for safety, should be already handled by cli parser
        // NOTE if an error is found here the bug is in the cli logic
        switch (self.property) {
            .power_limit, .gpu_clock, .mem_clock => {
                if (self.value == .int) {
                    std.debug.panic(">< int", .{});
                }
            },
            .gpu_clock_offset, .mem_clock_offset => {
                if (self.value == .uint) {
                    std.debug.panic(">< uint", .{});
                }
            },
            else => unreachable,
        }

        switch (self.property) {
            .power_limit => try gpu.setPowerLimit(self.value.uint),
            .gpu_clock => try gpu.setLockedClock(.gpu, self.value.uint, self.minval),
            .mem_clock => try gpu.setLockedClock(.mem, self.value.uint, self.minval),
            .gpu_clock_offset => try gpu.setClockOffset(.gpu, self.value.int),
            .mem_clock_offset => try gpu.setClockOffset(.mem, self.value.int),
            else => unreachable,
        }
    }
};

pub const ResetHandler = struct {
    property: Query,
    gpu: ?u16,

    pub fn run(self: ResetHandler, gpus: []Gpu) !void {
        if (gpus.len == 0) unreachable;

        const index = self.gpu orelse 0;
        if (index >= gpus.len) {
            std.log.err("invalid GPU index {d} (0-based)", .{index});
            return error.InvalidGpuIndex;
        }
        const gpu = &gpus[index];

        switch (self.property) {
            .power_limit => try gpu.resetPowerLimit(),
            .gpu_clock => try gpu.resetLockedClock(.gpu),
            .mem_clock => try gpu.resetLockedClock(.mem),
            .gpu_clock_offset => try gpu.setClockOffset(.gpu, 0),
            .mem_clock_offset => try gpu.setClockOffset(.mem, 0),
            else => unreachable,
        }
    }
};
