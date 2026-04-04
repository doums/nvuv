// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");

pub const c = @cImport({
    @cInclude("nvml.h");
});

// https://codeberg.org/ziglang/translate-c/issues/314
// Some variable are defined via a C macro using token pasting (##).
// Zig's c importer cannot expand it, and generates a @compileError
// So we redefine them manually.
//
// Eg. this macro expands to: sizeof(nvmlClockOffset_v1_t) | (1 << 24)
// C def: #define nvmlClockOffset_v1 NVML_STRUCT_VERSION(ClockOffset, 1)
pub const nvmlClockOffset_v1 = @as(c_uint, @sizeOf(c.nvmlClockOffset_v1_t)) | (1 << 24);
// C def: #define nvmlPowerValue_v2 NVML_STRUCT_VERSION(PowerValue, 2)
pub const nvmlPowerValue_v2 = @as(c_uint, @sizeOf(c.nvmlPowerValue_v2_t)) | (2 << 24);

pub fn nvmlCheck(res: c_uint) !void {
    switch (res) {
        c.NVML_SUCCESS => return,
        c.NVML_ERROR_NOT_SUPPORTED => {
            std.log.warn("feature not supported on this GPU", .{});
            return error.GpuNotSupported;
        },
        c.NVML_ERROR_NO_PERMISSION => {
            std.log.err("permission denied, root required", .{});
            return error.NoPermission;
        },
        else => {
            std.log.err("NVML: {s}", .{c.nvmlErrorString(res)});
            return error.NVML;
        },
    }
}
