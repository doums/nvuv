// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const c = @import("c.zig").c;
const nvmlCheck = @import("c.zig").nvmlCheck;
const nvmlClockOffset_v1 = @import("c.zig").nvmlClockOffset_v1;

const max_pstates = c.NVML_MAX_GPU_PERF_PSTATES;

pub const ClkType = enum {
    gpu,
    mem,

    pub fn str(self: ClkType) []const u8 {
        return switch (self) {
            .gpu => "gpu",
            .mem => "memory",
        };
    }
};

pub const Pstate = struct {
    num: u16,
    max_gpu_clock: u32, // in MHz
    min_gpu_clock: u32,
    max_mem_clock: u32,
    min_mem_clock: u32,
    gpu_clock_offset: i32,
    max_gpu_clock_offset: i32,
    min_gpu_clock_offset: i32,
    mem_clock_offset: i32,
    max_mem_clock_offset: i32,
    min_mem_clock_offset: i32,

    pub fn print(self: *const Pstate) void {
        std.debug.print(
            \\P{d}:
            \\  GPU clock range: {d}..{d} MHz
            \\  MEM clock range: {d}..{d} MHz
            \\  GPU clock offset: {d} ({d}..{d}) MHz
            \\  MEM clock offset: {d} ({d}..{d}) MHz
            \\
        , .{
            self.num,
            self.min_gpu_clock,
            self.max_gpu_clock,
            self.min_mem_clock,
            self.max_mem_clock,
            self.gpu_clock_offset,
            self.min_gpu_clock_offset,
            self.max_gpu_clock_offset,
            self.mem_clock_offset,
            self.min_mem_clock_offset,
            self.max_mem_clock_offset,
        });
    }

    pub fn getClockRange(self: *const Pstate, comptime clkt: ClkType) struct { min: u32, max: u32 } {
        return switch (clkt) {
            .gpu => .{ .min = self.min_gpu_clock, .max = self.max_gpu_clock },
            .mem => .{ .min = self.min_mem_clock, .max = self.max_mem_clock },
        };
    }

    pub fn getClockOffset(self: *const Pstate, comptime clkt: ClkType) struct {
        curr: i32,
        min: i32,
        max: i32,
    } {
        // feeling lazy today ;-
        return .{
            .curr = @field(self, @tagName(clkt) ++ "_clock_offset"),
            .min = @field(self, "min_" ++ @tagName(clkt) ++ "_clock_offset"),
            .max = @field(self, "max_" ++ @tagName(clkt) ++ "_clock_offset"),
        };
    }
};

pub const Pstates = struct {
    pstates: []Pstate,

    pub fn init(device: c.nvmlDevice_t, gpa: std.mem.Allocator) !Pstates {
        const nv_pstates = try gpa.alloc(c.nvmlPstates_t, max_pstates);
        defer gpa.free(nv_pstates);
        try nvmlCheck(c.nvmlDeviceGetSupportedPerformanceStates(
            device,
            nv_pstates.ptr,
            @intCast(max_pstates * @sizeOf(c.nvmlPstates_t)),
        ));
        // reverse sort to have high performance states first:
        // P0, P1, P2, …P15
        std.mem.sort(c.nvmlPstates_t, nv_pstates, {}, std.sort.asc(c.nvmlPstates_t));

        var gpu_offset_info: c.nvmlClockOffset_t = c.nvmlClockOffset_t{
            .version = nvmlClockOffset_v1,
            .pstate = 0,
            .type = c.NVML_CLOCK_GRAPHICS,
        };
        var mem_offset_info: c.nvmlClockOffset_t = c.nvmlClockOffset_t{
            .version = nvmlClockOffset_v1,
            .pstate = 0,
            .type = c.NVML_CLOCK_MEM,
        };
        var pstates = try std.ArrayList(Pstate).initCapacity(gpa, max_pstates);
        var min_gpu_clock: c_uint = 0;
        var max_gpu_clock: c_uint = 0;
        var min_mem_clock: c_uint = 0;
        var max_mem_clock: c_uint = 0;

        for (nv_pstates[0..max_pstates]) |pstate| {
            // skip unknown pstates
            if (pstate == c.NVML_PSTATE_UNKNOWN) {
                continue;
            }

            // get gpu clock range
            try nvmlCheck(c.nvmlDeviceGetMinMaxClockOfPState(
                device,
                c.NVML_CLOCK_GRAPHICS,
                pstate,
                &min_gpu_clock,
                &max_gpu_clock,
            ));

            // get mem clock range
            // NOTE: for some reason min and max are returned the
            // same on my GPU, ie. min = max for all pstates
            try nvmlCheck(c.nvmlDeviceGetMinMaxClockOfPState(
                device,
                c.NVML_CLOCK_MEM,
                pstate,
                &min_mem_clock,
                &max_mem_clock,
            ));

            gpu_offset_info.pstate = pstate;
            mem_offset_info.pstate = pstate;

            // get gpu clock offset
            try nvmlCheck(c.nvmlDeviceGetClockOffsets(
                device,
                &gpu_offset_info,
            ));

            // get mem clock offset
            try nvmlCheck(c.nvmlDeviceGetClockOffsets(
                device,
                &mem_offset_info,
            ));

            pstates.appendAssumeCapacity(Pstate{
                .num = @intCast(pstate),
                .max_gpu_clock = max_gpu_clock,
                .min_gpu_clock = min_gpu_clock,
                .max_mem_clock = max_mem_clock,
                .min_mem_clock = min_mem_clock,
                .gpu_clock_offset = gpu_offset_info.clockOffsetMHz,
                .max_gpu_clock_offset = gpu_offset_info.maxClockOffsetMHz,
                .min_gpu_clock_offset = gpu_offset_info.minClockOffsetMHz,
                .mem_clock_offset = mem_offset_info.clockOffsetMHz,
                .max_mem_clock_offset = mem_offset_info.maxClockOffsetMHz,
                .min_mem_clock_offset = mem_offset_info.minClockOffsetMHz,
            });
        }

        return Pstates{
            .pstates = try pstates.toOwnedSlice(gpa),
        };
    }

    pub fn getClockRange(self: *const Pstates, comptime clkt: ClkType) struct { min: u32, max: u32 } {
        var min: u32 = 0xffffffff;
        var max: u32 = 0;
        for (self.pstates) |pstate| {
            const clocks = pstate.getClockRange(clkt);
            if (clocks.min < min) {
                min = clocks.min;
            }
            if (clocks.max > max) {
                max = clocks.max;
            }
        }
        return .{ .min = min, .max = max };
    }

    pub fn getClockOffset(self: *const Pstates, comptime clkt: ClkType) struct { curr: i32, min: i32, max: i32 } {
        var min: i32 = 0x7fffffff;
        var max: i32 = -0x80000000;
        var curr: i32 = 0;
        for (self.pstates) |pstate| {
            const offsets = pstate.getClockOffset(clkt);
            if (pstate.num == 0) {
                curr = offsets.curr;
            }
            if (offsets.min < min) {
                min = offsets.min;
            }
            if (offsets.max > max) {
                max = offsets.max;
            }
        }
        return .{ .curr = curr, .min = min, .max = max };
    }

    pub fn getPState(self: *const Pstates, num: u16) ?Pstate {
        for (self.pstates) |pstate| {
            if (pstate.num == num) return pstate;
        }
        return null;
    }

    pub fn highestPState(self: *const Pstates) Pstate {
        return self.pstates[0];
    }

    pub fn deinit(self: *Pstates, gpa: std.mem.Allocator) void {
        gpa.free(self.pstates);
    }

    pub fn printPStateIndexes(self: *const Pstates) void {
        std.debug.print("Supported P-states: ", .{});
        for (self.pstates, 0..) |pstate, i| {
            if (i != 0) {
                std.debug.print(", ", .{});
            }
            std.debug.print("P{d}", .{pstate.num});
        }
        std.debug.print("\n", .{});
    }
};
