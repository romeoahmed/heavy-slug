//! CPU representation of optional shader diagnostic counters.

const std = @import("std");

/// Number of u32 counters exposed by the shader ABI.
pub const counter_count: usize = 6;

/// Counter order must match `slug_fragment.slang`.
pub const CounterIndex = enum(u32) {
    fragment_invocations = 0,
    candidate_path_fragments = 1,
    full_scan_fragments = 2,
    candidate_curve_tests = 3,
    full_scan_curve_tests = 4,
    empty_fragments = 5,
};

/// Snapshot copied from the shader counter buffer.
pub const Snapshot = extern struct {
    fragment_invocations: u32 = 0,
    candidate_path_fragments: u32 = 0,
    full_scan_fragments: u32 = 0,
    candidate_curve_tests: u32 = 0,
    full_scan_curve_tests: u32 = 0,
    empty_fragments: u32 = 0,

    pub fn reset(self: *Snapshot) void {
        self.* = .{};
    }

    pub fn fromCounters(counters: *const [counter_count]u32) Snapshot {
        return .{
            .fragment_invocations = counters[@intFromEnum(CounterIndex.fragment_invocations)],
            .candidate_path_fragments = counters[@intFromEnum(CounterIndex.candidate_path_fragments)],
            .full_scan_fragments = counters[@intFromEnum(CounterIndex.full_scan_fragments)],
            .candidate_curve_tests = counters[@intFromEnum(CounterIndex.candidate_curve_tests)],
            .full_scan_curve_tests = counters[@intFromEnum(CounterIndex.full_scan_curve_tests)],
            .empty_fragments = counters[@intFromEnum(CounterIndex.empty_fragments)],
        };
    }
};

test "shader stats counter ABI is a packed u32 array" {
    try std.testing.expectEqual(@as(usize, counter_count * @sizeOf(u32)), @sizeOf(Snapshot));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(CounterIndex.full_scan_curve_tests));
}
