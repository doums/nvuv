// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const c = @import("c.zig").c;
const nvmlPowerValue_v2 = @import("c.zig").nvmlPowerValue_v2;
const nvmlClockOffset_v1 = @import("c.zig").nvmlClockOffset_v1;
const ClkType = @import("pstates.zig").ClkType;
const nvmlCheck = @import("c.zig").nvmlCheck;
const Pstates = @import("pstates.zig").Pstates;
const GpuConfig = @import("config.zig").GpuConfig;

const power_scope = c.NVML_POWER_SCOPE_GPU;
const dev_name_buf = c.NVML_DEVICE_NAME_V2_BUFFER_SIZE;
const dev_uuid_buf = c.NVML_DEVICE_UUID_V2_BUFFER_SIZE;
const bus_id_buf = c.NVML_DEVICE_PCI_BUS_ID_BUFFER_SIZE;
const vbios_buf = c.NVML_DEVICE_VBIOS_VERSION_BUFFER_SIZE;
const kib = 1024;
const mib = kib * 1024;
const gib = mib * 1024;

pub const Gpu = struct {
    device: c.nvmlDevice_t,
    index: usize,
    name: []u8, // owned memory
    uuid: []u8, // owned memory
    pci_bus_id: []u8, // owned memory
    vbios_version: []u8, // owned memory
    default_power_limit: u32, // milliwatts (mW)
    max_power_limit: u32,
    min_power_limit: u32,
    curr_power_limit: u32,
    vendor_id: u32,
    device_id: u32,
    memory_total: u64, // bytes
    cuda_cores: u32,
    arch: u32,
    link_gen: u32, // PCIe generation (1, 2, 3, 4, 5)
    max_link_gen: u32,
    link_width: u32, // number of PCIe lanes
    max_link_width: u32,
    max_link_speed: u32, // MBPS
    bar1: bool,
    bar1_mem: u64, // bytes
    pstates: Pstates,

    pub fn from_index(index: usize, gpa: std.mem.Allocator) !Gpu {
        var device: c.nvmlDevice_t = undefined;
        var name: [dev_name_buf:0]u8 = undefined;
        var uuid: [dev_uuid_buf:0]u8 = undefined;
        var vbios_version: [vbios_buf:0]u8 = undefined;
        var pci_info: c.nvmlPciInfo_t = undefined;
        var memory_info: c.nvmlMemory_t = undefined;
        var default_power_limit_w: c_uint = 0;
        var max_power_limit_w: c_uint = 0;
        var min_power_limit_w: c_uint = 0;
        var curr_power_limit_w: c_uint = 0;
        var num_cores: c_uint = 0;
        var arch: c_uint = 0;
        var link_gen: c_uint = 0;
        var link_gen_max: c_uint = 0;
        var link_width: c_uint = 0;
        var max_link_width: c_uint = 0;
        var max_link_speed: c_uint = 0;
        var bar1_mem = c.nvmlBAR1Memory_t{
            .bar1Total = 0,
            .bar1Free = 0,
            .bar1Used = 0,
        };
        var bar1_enabled = false;

        // zig's usize = 64bits, nvml APIs expect c_uint = 32bits
        // so let's cast
        try nvmlCheck(c.nvmlDeviceGetHandleByIndex(@intCast(index), &device));
        try nvmlCheck(c.nvmlDeviceGetName(device, &name, @intCast(name.len)));
        try nvmlCheck(c.nvmlDeviceGetUUID(device, &uuid, @intCast(uuid.len)));
        try nvmlCheck(c.nvmlDeviceGetPciInfo(device, &pci_info));
        try nvmlCheck(c.nvmlDeviceGetPowerManagementDefaultLimit(device, &default_power_limit_w));
        try nvmlCheck(c.nvmlDeviceGetPowerManagementLimitConstraints(device, &min_power_limit_w, &max_power_limit_w));
        try nvmlCheck(c.nvmlDeviceGetPowerManagementLimit(device, &curr_power_limit_w));
        try nvmlCheck(c.nvmlDeviceGetVbiosVersion(device, &vbios_version, @intCast(vbios_version.len)));
        try nvmlCheck(c.nvmlDeviceGetMemoryInfo(device, &memory_info));
        try nvmlCheck(c.nvmlDeviceGetNumGpuCores(device, &num_cores));
        try nvmlCheck(c.nvmlDeviceGetArchitecture(device, &arch));
        try nvmlCheck(c.nvmlDeviceGetMaxPcieLinkGeneration(device, &link_gen_max));
        try nvmlCheck(c.nvmlDeviceGetCurrPcieLinkGeneration(device, &link_gen));
        try nvmlCheck(c.nvmlDeviceGetMaxPcieLinkWidth(device, &max_link_width));
        try nvmlCheck(c.nvmlDeviceGetCurrPcieLinkWidth(device, &link_width));
        try nvmlCheck(c.nvmlDeviceGetPcieLinkMaxSpeed(device, &max_link_speed));

        const pstates = try Pstates.init(device, gpa);

        nvmlCheck(c.nvmlDeviceGetBAR1MemoryInfo(device, &bar1_mem)) catch |err| switch (err) {
            error.GpuNotSupported => {},
            else => return err,
        };
        bar1_enabled = bar1_mem.bar1Total > (256 * 1024 * 1024);

        const vendor_id = pci_info.pciDeviceId & 0xFFFF;
        const device_id = (pci_info.pciDeviceId >> 16) & 0xFFFF;

        // from C side we have fix-sized buffers with null-terminated strings,
        // so we need to slice them to get the actual content length
        // then copy to owned memory so we can store it in the struct
        const owned_name = try gpa.dupe(u8, std.mem.sliceTo(&name, 0));
        const owned_uuid = try gpa.dupe(u8, std.mem.sliceTo(&uuid, 0));
        const owned_vbios = try gpa.dupe(u8, std.mem.sliceTo(&vbios_version, 0));
        const pci_bus_id = try gpa.dupe(u8, std.mem.sliceTo(&pci_info.busId, 0));

        return Gpu{
            .device = device,
            .index = index,
            .name = owned_name,
            .uuid = owned_uuid,
            .vbios_version = owned_vbios,
            .pci_bus_id = pci_bus_id,
            .vendor_id = vendor_id,
            .device_id = device_id,
            .default_power_limit = default_power_limit_w,
            .max_power_limit = max_power_limit_w,
            .min_power_limit = min_power_limit_w,
            .curr_power_limit = curr_power_limit_w,
            .memory_total = memory_info.total,
            .cuda_cores = num_cores,
            .arch = arch,
            .link_gen = link_gen,
            .max_link_gen = link_gen_max,
            .link_width = link_width,
            .max_link_width = max_link_width,
            .max_link_speed = max_link_speed,
            .bar1 = bar1_enabled,
            .bar1_mem = bar1_mem.bar1Total,
            .pstates = pstates,
        };
    }

    pub fn deinit(self: *Gpu, gpa: std.mem.Allocator) void {
        self.pstates.deinit(gpa);
        gpa.free(self.name);
        gpa.free(self.uuid);
        gpa.free(self.vbios_version);
        gpa.free(self.pci_bus_id);
    }

    pub fn print(self: *const Gpu) void {
        const total_gib: f64 = @as(f64, @floatFromInt(self.memory_total)) / gib;

        std.debug.print(
            \\[GPU{d}]
            \\Name: {s} ({x:0>4}:{x:0>4})
            \\Arch: {s}
            \\UUID: {s}
            \\VBIOS version: {s}
            \\PCI bus ID: {s}
            \\CUDA cores: {d}
            \\VRAM size: {d:.2} GiB
            \\Resizable BAR1: {s} ({d} MiB)
            \\PCIe link: Gen {d} x{d} (max Gen {d} x{d})
            \\PCIe link max: Gen {d}
            \\
        , .{
            self.index,
            self.name,
            self.vendor_id,
            self.device_id,
            archToString(self.arch),
            self.uuid,
            self.vbios_version,
            self.pci_bus_id,
            self.cuda_cores,
            total_gib,
            if (self.bar1) "Yes" else "No",
            self.bar1_mem / mib,
            self.link_gen,
            self.link_width,
            self.max_link_gen,
            self.max_link_width,
            linkSpeedToGen(self.max_link_speed) catch 0,
        });
    }

    pub fn setPowerLimit(self: *const Gpu, power_limit_w: u32) !void {
        const min_limit_w = self.min_power_limit / 1000;
        const max_limit_w = self.max_power_limit / 1000;
        if (power_limit_w < min_limit_w or power_limit_w > max_limit_w) {
            std.log.err("power limit {d}W is out of range ({d}..{d}W)", .{
                power_limit_w,
                min_limit_w,
                max_limit_w,
            });
            return error.InvalidValue;
        }
        var nvml_val = c.nvmlPowerValue_v2_t{
            .version = nvmlPowerValue_v2,
            .powerScope = power_scope,
            .powerValueMw = power_limit_w * 1000, // convert W to mW
        };
        try nvmlCheck(c.nvmlDeviceSetPowerManagementLimit_v2(self.device, &nvml_val));
        std.debug.print("power limit set to {d}W\n", .{power_limit_w});
    }

    pub fn resetPowerLimit(self: *const Gpu) !void {
        var nvml_val = c.nvmlPowerValue_v2_t{
            .version = nvmlPowerValue_v2,
            .powerScope = power_scope,
            .powerValueMw = self.default_power_limit,
        };
        try nvmlCheck(c.nvmlDeviceSetPowerManagementLimit_v2(self.device, &nvml_val));
        std.debug.print("power limit reset to default {d}W\n", .{self.default_power_limit / 1000});
    }

    pub fn setLockedClock(
        self: *const Gpu,
        comptime clkt: ClkType,
        max_clock_mhz: u32,
        min_clock_mhz: ?u32,
    ) !void {
        const range = self.pstates.getClockRange(clkt);
        const min_clock = min_clock_mhz orelse range.min;
        if (max_clock_mhz < range.min or max_clock_mhz > range.max) {
            std.log.err("max {s} clock {d}MHz is out of range ({d}..{d}MHz)", .{
                clkt.str(),
                max_clock_mhz,
                range.min,
                range.max,
            });
            return error.InvalidValue;
        }
        if (min_clock < range.min or min_clock > range.max) {
            std.log.err("min {s} clock {d}MHz is out of range ({d}..{d}MHz)", .{
                clkt.str(),
                min_clock,
                range.min,
                range.max,
            });
            return error.InvalidValue;
        }
        const setLockedClockFn = switch (clkt) {
            .gpu => c.nvmlDeviceSetGpuLockedClocks,
            .mem => c.nvmlDeviceSetMemoryLockedClocks,
        };
        try nvmlCheck(@call(.auto, setLockedClockFn, .{ self.device, min_clock, max_clock_mhz }));
        std.debug.print("{s} locked clock set to {d}..{d}MHz\n", .{
            clkt.str(),
            min_clock,
            max_clock_mhz,
        });
    }

    pub fn resetLockedClock(self: *const Gpu, comptime clkt: ClkType) !void {
        const resetLockedClockFn = switch (clkt) {
            .gpu => c.nvmlDeviceResetGpuLockedClocks,
            .mem => c.nvmlDeviceResetMemoryLockedClocks,
        };
        try nvmlCheck(@call(.auto, resetLockedClockFn, .{self.device}));
        std.debug.print("{s} locked clock reset to default\n", .{
            clkt.str(),
        });
    }

    // NOTE: Despite taking a pstate parameter, nvmlDeviceSetClockOffsets
    // applies the offset globally to all pstates — this is a known
    // NVML/driver limitation. At least I experienced it on my own HW.
    // The pstate field is only used to look up the valid min/max
    // offset range for that pstate.
    pub fn setClockOffset(
        self: *const Gpu,
        comptime clkt: ClkType,
        offset_mhz: i32,
    ) !void {
        const pstate = self.pstates.highestPState();
        const range = pstate.getClockOffset(clkt);
        if (offset_mhz < range.min or offset_mhz > range.max) {
            std.log.err("P{d}: {s} clock offset {d}MHz is out of range ({d}..{d}MHz)", .{
                pstate.num,
                clkt.str(),
                offset_mhz,
                range.min,
                range.max,
            });
            return error.InvalidValue;
        }
        const clock_type = switch (clkt) {
            .gpu => c.NVML_CLOCK_GRAPHICS,
            .mem => c.NVML_CLOCK_MEM,
        };
        var info = c.nvmlClockOffset_t{
            .version = nvmlClockOffset_v1,
            .type = clock_type,
            .pstate = pstate.num,
            .clockOffsetMHz = offset_mhz,
        };
        try nvmlCheck(c.nvmlDeviceSetClockOffsets(self.device, &info));
        std.debug.print("P{d}: {s} clock offset set to {d}MHz\n", .{ pstate.num, clkt.str(), offset_mhz });
    }

    pub fn printPStates(self: *const Gpu) void {
        self.pstates.print();
    }

    pub fn printPowerLimit(self: *const Gpu) void {
        std.debug.print("power limit: {d}W (default: {d}W, range: {d}..{d}W)\n", .{
            self.curr_power_limit / 1000,
            self.default_power_limit / 1000,
            self.min_power_limit / 1000,
            self.max_power_limit / 1000,
        });
    }

    pub fn printClock(self: *const Gpu, comptime clkt: ClkType, pstate_num: ?u16) !void {
        if (pstate_num) |num| {
            const pstate = self.pstates.getPState(num) orelse {
                std.log.err("invalid P-state {d}", .{num});
                self.pstates.printPStateIndexes();
                return error.InvalidPState;
            };
            const range = pstate.getClockRange(clkt);
            std.debug.print("P{d}: {s} clock range: {d}..{d}MHz\n", .{
                num,
                clkt.str(),
                range.min,
                range.max,
            });
        } else {
            const range = self.pstates.getClockRange(clkt);
            std.debug.print("{s} clock range: {d}..{d}MHz\n", .{
                clkt.str(),
                range.min,
                range.max,
            });
        }
    }

    pub fn printClockOffset(self: *const Gpu, comptime clkt: ClkType, pstate_num: ?u16) !void {
        if (pstate_num) |num| {
            const pstate = self.pstates.getPState(num) orelse {
                std.log.err("invalid P-state {d}", .{num});
                self.pstates.printPStateIndexes();
                return error.InvalidPState;
            };
            const offset = pstate.getClockOffset(clkt);
            std.debug.print("P{d}: {s} clock offset: {d}MHz ({d}..{d})\n", .{
                num,
                clkt.str(),
                offset.curr,
                offset.min,
                offset.max,
            });
        } else {
            const offset = self.pstates.getClockOffset(clkt);
            std.debug.print("{s} clock offset: {d}MHz ({d}..{d})\n", .{
                clkt.str(),
                offset.curr,
                offset.min,
                offset.max,
            });
        }
    }

    pub fn printSupportedPStates(self: *const Gpu) void {
        self.pstates.printPStateIndexes();
    }

    pub fn printPStateClocks(self: *const Gpu, pstate_num: ?u16) !void {
        if (pstate_num) |num| {
            const pstate = self.pstates.getPState(num) orelse {
                std.log.err("invalid P-state {d}", .{num});
                self.pstates.printPStateIndexes();
                return error.InvalidPState;
            };
            pstate.print();
        } else {
            for (self.pstates.pstates) |pstate| {
                pstate.print();
            }
        }
    }

    pub fn applyConfig(self: *const Gpu, config: GpuConfig) void {
        std.debug.print("GPU{d}: applying config\n", .{self.index});
        var error_hit: u32 = 0;
        if (config.power_limit) |limit| {
            self.setPowerLimit(limit) catch |err| {
                std.log.err("GPU{d}: failed to set power limit: {s}", .{ self.index, @errorName(err) });
                error_hit += 1;
            };
        }
        if (config.gpu_locked_clocks) |range| {
            self.setLockedClock(.gpu, range.max, range.min) catch |err| {
                std.log.err("GPU{d}: failed to set gpu locked clock: {s}", .{ self.index, @errorName(err) });
                error_hit += 1;
            };
        }
        if (config.mem_locked_clocks) |range| {
            self.setLockedClock(.mem, range.max, range.min) catch |err| {
                std.log.err("GPU{d}: failed to set memory locked clock: {s}", .{ self.index, @errorName(err) });
                error_hit += 1;
            };
        }
        if (config.gpu_offset) |offset| {
            self.setClockOffset(.gpu, offset) catch |err| {
                std.log.err("GPU{d}: failed to set gpu clock offset: {s}", .{ self.index, @errorName(err) });
                error_hit += 1;
            };
        }
        if (config.mem_offset) |offset| {
            self.setClockOffset(.mem, offset) catch |err| {
                std.log.err("GPU{d}: failed to set memory clock offset: {s}", .{ self.index, @errorName(err) });
                error_hit += 1;
            };
        }
        if (error_hit > 0) {
            std.log.warn("GPU{d}: config applied with {d} errors", .{ self.index, error_hit });
        }
    }
};

fn archToString(arch: usize) []const u8 {
    return switch (arch) {
        c.NVML_DEVICE_ARCH_KEPLER => "Kepler",
        c.NVML_DEVICE_ARCH_MAXWELL => "Maxwell",
        c.NVML_DEVICE_ARCH_PASCAL => "Pascal",
        c.NVML_DEVICE_ARCH_VOLTA => "Volta",
        c.NVML_DEVICE_ARCH_TURING => "Turing",
        c.NVML_DEVICE_ARCH_AMPERE => "Ampere",
        c.NVML_DEVICE_ARCH_ADA => "Ada",
        c.NVML_DEVICE_ARCH_HOPPER => "Hopper",
        c.NVML_DEVICE_ARCH_BLACKWELL => "Blackwell",
        else => "Unknown",
    };
}

fn linkSpeedToGen(speed: u32) !usize {
    return switch (speed) {
        c.NVML_PCIE_LINK_MAX_SPEED_2500MBPS => 1,
        c.NVML_PCIE_LINK_MAX_SPEED_5000MBPS => 2,
        c.NVML_PCIE_LINK_MAX_SPEED_8000MBPS => 3,
        c.NVML_PCIE_LINK_MAX_SPEED_16000MBPS => 4,
        c.NVML_PCIE_LINK_MAX_SPEED_32000MBPS => 5,
        c.NVML_PCIE_LINK_MAX_SPEED_64000MBPS => 6,
        else => error.InvalidLinkSpeed,
    };
}
