//! CPU representation of optional shader diagnostic counters.

const std = @import("std");

/// Number of u32 counters exposed by the shader ABI.
pub const counter_count: usize = 19;

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
    candidate_curve_bbox_rejects = 11,
    full_scan_curve_bbox_rejects = 12,
    candidate_curve_integrations = 13,
    full_scan_curve_integrations = 14,
    bbox_empty_fragments = 15,
    coverage_zero_fragments = 16,
    mesh_tiles_emitted = 17,
    mesh_tiles_culled = 18,
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
    candidate_curve_bbox_rejects: u32 = 0,
    full_scan_curve_bbox_rejects: u32 = 0,
    candidate_curve_integrations: u32 = 0,
    full_scan_curve_integrations: u32 = 0,
    bbox_empty_fragments: u32 = 0,
    coverage_zero_fragments: u32 = 0,
    mesh_tiles_emitted: u32 = 0,
    mesh_tiles_culled: u32 = 0,

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
            .candidate_curve_bbox_rejects = counters[@intFromEnum(CounterIndex.candidate_curve_bbox_rejects)],
            .full_scan_curve_bbox_rejects = counters[@intFromEnum(CounterIndex.full_scan_curve_bbox_rejects)],
            .candidate_curve_integrations = counters[@intFromEnum(CounterIndex.candidate_curve_integrations)],
            .full_scan_curve_integrations = counters[@intFromEnum(CounterIndex.full_scan_curve_integrations)],
            .bbox_empty_fragments = counters[@intFromEnum(CounterIndex.bbox_empty_fragments)],
            .coverage_zero_fragments = counters[@intFromEnum(CounterIndex.coverage_zero_fragments)],
            .mesh_tiles_emitted = counters[@intFromEnum(CounterIndex.mesh_tiles_emitted)],
            .mesh_tiles_culled = counters[@intFromEnum(CounterIndex.mesh_tiles_culled)],
        };
    }

    pub fn totalCurveTests(self: Snapshot) u32 {
        return self.candidate_curve_tests + self.full_scan_curve_tests;
    }

    pub fn totalCurveBboxRejects(self: Snapshot) u32 {
        return self.candidate_curve_bbox_rejects + self.full_scan_curve_bbox_rejects;
    }

    pub fn totalCurveIntegrations(self: Snapshot) u32 {
        return self.candidate_curve_integrations + self.full_scan_curve_integrations;
    }

    pub fn analysis(self: Snapshot) Analysis {
        return .{
            .task_cull_per_mille = perMille(self.task_glyphs_culled, self.task_glyphs_tested),
            .full_scan_fragment_per_mille = perMille(self.full_scan_fragments, self.fragment_invocations),
            .bbox_reject_per_mille = perMille(self.totalCurveBboxRejects(), self.totalCurveTests()),
            .bbox_empty_fragment_per_mille = perMille(self.bbox_empty_fragments, self.fragment_invocations),
            .coverage_zero_fragment_per_mille = perMille(self.coverage_zero_fragments, self.fragment_invocations),
            .fragments_per_visible_glyph_milli = perMille(self.fragment_invocations, self.task_glyphs_visible),
            .fragments_per_mesh_tile_milli = perMille(self.fragment_invocations, self.mesh_tiles_emitted),
            .curve_tests_per_fragment_milli = perMille(self.totalCurveTests(), self.fragment_invocations),
            .curve_integrations_per_fragment_milli = perMille(self.totalCurveIntegrations(), self.fragment_invocations),
        };
    }
};

/// Integer ratios scaled by 1000 for stable debug logging.
pub const Analysis = struct {
    task_cull_per_mille: u32 = 0,
    full_scan_fragment_per_mille: u32 = 0,
    bbox_reject_per_mille: u32 = 0,
    bbox_empty_fragment_per_mille: u32 = 0,
    coverage_zero_fragment_per_mille: u32 = 0,
    fragments_per_visible_glyph_milli: u32 = 0,
    fragments_per_mesh_tile_milli: u32 = 0,
    curve_tests_per_fragment_milli: u32 = 0,
    curve_integrations_per_fragment_milli: u32 = 0,
};

fn perMille(numerator: u32, denominator: u32) u32 {
    if (denominator == 0) return 0;
    return @intCast((@as(u64, numerator) * 1000) / denominator);
}

test "shader stats counter ABI is a packed u32 array" {
    try std.testing.expectEqual(@as(usize, counter_count * @sizeOf(u32)), @sizeOf(Snapshot));
    try std.testing.expectEqual(@as(u32, 18), @intFromEnum(CounterIndex.mesh_tiles_culled));
}

test "shader stats snapshot maps task and mesh counters" {
    var counters = [_]u32{0} ** counter_count;
    counters[@intFromEnum(CounterIndex.task_workgroups)] = 3;
    counters[@intFromEnum(CounterIndex.task_glyphs_tested)] = 96;
    counters[@intFromEnum(CounterIndex.task_glyphs_visible)] = 60;
    counters[@intFromEnum(CounterIndex.task_glyphs_culled)] = 36;
    counters[@intFromEnum(CounterIndex.mesh_workgroups)] = 60;
    counters[@intFromEnum(CounterIndex.candidate_curve_bbox_rejects)] = 400;
    counters[@intFromEnum(CounterIndex.full_scan_curve_bbox_rejects)] = 12;
    counters[@intFromEnum(CounterIndex.candidate_curve_integrations)] = 500;
    counters[@intFromEnum(CounterIndex.full_scan_curve_integrations)] = 8;
    counters[@intFromEnum(CounterIndex.bbox_empty_fragments)] = 20;
    counters[@intFromEnum(CounterIndex.coverage_zero_fragments)] = 30;
    counters[@intFromEnum(CounterIndex.mesh_tiles_emitted)] = 44;
    counters[@intFromEnum(CounterIndex.mesh_tiles_culled)] = 16;

    const snapshot = Snapshot.fromCounters(&counters);
    try std.testing.expectEqual(@as(u32, 3), snapshot.task_workgroups);
    try std.testing.expectEqual(@as(u32, 96), snapshot.task_glyphs_tested);
    try std.testing.expectEqual(@as(u32, 60), snapshot.task_glyphs_visible);
    try std.testing.expectEqual(@as(u32, 36), snapshot.task_glyphs_culled);
    try std.testing.expectEqual(@as(u32, 60), snapshot.mesh_workgroups);
    try std.testing.expectEqual(@as(u32, 400), snapshot.candidate_curve_bbox_rejects);
    try std.testing.expectEqual(@as(u32, 12), snapshot.full_scan_curve_bbox_rejects);
    try std.testing.expectEqual(@as(u32, 500), snapshot.candidate_curve_integrations);
    try std.testing.expectEqual(@as(u32, 8), snapshot.full_scan_curve_integrations);
    try std.testing.expectEqual(@as(u32, 20), snapshot.bbox_empty_fragments);
    try std.testing.expectEqual(@as(u32, 30), snapshot.coverage_zero_fragments);
    try std.testing.expectEqual(@as(u32, 44), snapshot.mesh_tiles_emitted);
    try std.testing.expectEqual(@as(u32, 16), snapshot.mesh_tiles_culled);
}

test "shader stats analysis derives bottleneck ratios" {
    const snapshot = Snapshot{
        .fragment_invocations = 100,
        .full_scan_fragments = 25,
        .candidate_curve_tests = 200,
        .full_scan_curve_tests = 100,
        .task_glyphs_tested = 80,
        .task_glyphs_visible = 20,
        .task_glyphs_culled = 20,
        .mesh_tiles_emitted = 25,
        .candidate_curve_bbox_rejects = 150,
        .full_scan_curve_bbox_rejects = 30,
        .candidate_curve_integrations = 50,
        .full_scan_curve_integrations = 70,
        .bbox_empty_fragments = 10,
        .coverage_zero_fragments = 15,
    };

    try std.testing.expectEqual(@as(u32, 300), snapshot.totalCurveTests());
    try std.testing.expectEqual(@as(u32, 180), snapshot.totalCurveBboxRejects());
    try std.testing.expectEqual(@as(u32, 120), snapshot.totalCurveIntegrations());

    const analysis_result = snapshot.analysis();
    try std.testing.expectEqual(@as(u32, 250), analysis_result.task_cull_per_mille);
    try std.testing.expectEqual(@as(u32, 250), analysis_result.full_scan_fragment_per_mille);
    try std.testing.expectEqual(@as(u32, 600), analysis_result.bbox_reject_per_mille);
    try std.testing.expectEqual(@as(u32, 100), analysis_result.bbox_empty_fragment_per_mille);
    try std.testing.expectEqual(@as(u32, 150), analysis_result.coverage_zero_fragment_per_mille);
    try std.testing.expectEqual(@as(u32, 5000), analysis_result.fragments_per_visible_glyph_milli);
    try std.testing.expectEqual(@as(u32, 4000), analysis_result.fragments_per_mesh_tile_milli);
    try std.testing.expectEqual(@as(u32, 3000), analysis_result.curve_tests_per_fragment_milli);
    try std.testing.expectEqual(@as(u32, 1200), analysis_result.curve_integrations_per_fragment_milli);
}
