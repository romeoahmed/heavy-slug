//! CPU representation of optional shader diagnostic counters.

const std = @import("std");

/// Number of u32 counters exposed by the shader ABI.
pub const counter_count: usize = 11;

/// Counter order must match the shader-stage constants in `shaders/entries/`.
pub const CounterIndex = enum(u32) {
    fragment_invocations = 0,
    candidate_path_fragments = 1,
    full_scan_fragments = 2,
    candidate_curve_tests = 3,
    full_scan_curve_tests = 4,
    empty_fragments = 5,
    task_workgroups = 6,
    task_glyphs_tested = 7,
    task_glyphs_visible = 8,
    task_glyphs_culled = 9,
    mesh_workgroups = 10,
};

/// Snapshot copied from the shader counter buffer.
pub const Snapshot = extern struct {
    fragment_invocations: u32 = 0,
    candidate_path_fragments: u32 = 0,
    full_scan_fragments: u32 = 0,
    candidate_curve_tests: u32 = 0,
    full_scan_curve_tests: u32 = 0,
    empty_fragments: u32 = 0,
    task_workgroups: u32 = 0,
    task_glyphs_tested: u32 = 0,
    task_glyphs_visible: u32 = 0,
    task_glyphs_culled: u32 = 0,
    mesh_workgroups: u32 = 0,

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
            .task_workgroups = counters[@intFromEnum(CounterIndex.task_workgroups)],
            .task_glyphs_tested = counters[@intFromEnum(CounterIndex.task_glyphs_tested)],
            .task_glyphs_visible = counters[@intFromEnum(CounterIndex.task_glyphs_visible)],
            .task_glyphs_culled = counters[@intFromEnum(CounterIndex.task_glyphs_culled)],
            .mesh_workgroups = counters[@intFromEnum(CounterIndex.mesh_workgroups)],
        };
    }
};

test "shader stats counter ABI is a packed u32 array" {
    try std.testing.expectEqual(@as(usize, counter_count * @sizeOf(u32)), @sizeOf(Snapshot));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(CounterIndex.mesh_workgroups));
}

test "shader stats snapshot maps task and mesh counters" {
    var counters = [_]u32{0} ** counter_count;
    counters[@intFromEnum(CounterIndex.task_workgroups)] = 3;
    counters[@intFromEnum(CounterIndex.task_glyphs_tested)] = 96;
    counters[@intFromEnum(CounterIndex.task_glyphs_visible)] = 60;
    counters[@intFromEnum(CounterIndex.task_glyphs_culled)] = 36;
    counters[@intFromEnum(CounterIndex.mesh_workgroups)] = 60;

    const snapshot = Snapshot.fromCounters(&counters);
    try std.testing.expectEqual(@as(u32, 3), snapshot.task_workgroups);
    try std.testing.expectEqual(@as(u32, 96), snapshot.task_glyphs_tested);
    try std.testing.expectEqual(@as(u32, 60), snapshot.task_glyphs_visible);
    try std.testing.expectEqual(@as(u32, 36), snapshot.task_glyphs_culled);
    try std.testing.expectEqual(@as(u32, 60), snapshot.mesh_workgroups);
}
