//! CPU representation of optional shader diagnostic counters.

const std = @import("std");

/// Number of u32 counters exposed by the shader ABI.
pub const counter_count: usize = 24;

/// Counter order must match `shaders/core/stats.slang`.
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
    mesh_cull_empty_slices = 19,
    mesh_cull_invalid_strips = 20,
    mesh_cull_zero_area = 21,
    mesh_cull_clip_empty = 22,
    mesh_cull_non_finite = 23,
};

pub const MeshCullBreakdown = struct {
    empty_slices: u32 = 0,
    invalid_strips: u32 = 0,
    zero_area: u32 = 0,
    clip_empty: u32 = 0,
    non_finite: u32 = 0,

    pub fn total(self: MeshCullBreakdown) u32 {
        return self.empty_slices +
            self.invalid_strips +
            self.zero_area +
            self.clip_empty +
            self.non_finite;
    }
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
    mesh_cull_empty_slices: u32 = 0,
    mesh_cull_invalid_strips: u32 = 0,
    mesh_cull_zero_area: u32 = 0,
    mesh_cull_clip_empty: u32 = 0,
    mesh_cull_non_finite: u32 = 0,

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
            .mesh_cull_empty_slices = counters[@intFromEnum(CounterIndex.mesh_cull_empty_slices)],
            .mesh_cull_invalid_strips = counters[@intFromEnum(CounterIndex.mesh_cull_invalid_strips)],
            .mesh_cull_zero_area = counters[@intFromEnum(CounterIndex.mesh_cull_zero_area)],
            .mesh_cull_clip_empty = counters[@intFromEnum(CounterIndex.mesh_cull_clip_empty)],
            .mesh_cull_non_finite = counters[@intFromEnum(CounterIndex.mesh_cull_non_finite)],
        };
    }

    pub fn fromBytes(bytes: []align(@alignOf(u32)) const u8) Snapshot {
        std.debug.assert(bytes.len >= @sizeOf(Snapshot));
        const counters: *const [counter_count]u32 = @ptrCast(bytes.ptr);
        return fromCounters(counters);
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

    pub fn meshCullBreakdown(self: Snapshot) MeshCullBreakdown {
        return .{
            .empty_slices = self.mesh_cull_empty_slices,
            .invalid_strips = self.mesh_cull_invalid_strips,
            .zero_area = self.mesh_cull_zero_area,
            .clip_empty = self.mesh_cull_clip_empty,
            .non_finite = self.mesh_cull_non_finite,
        };
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
            .mesh_cull_accounted_per_mille = perMille(self.meshCullBreakdown().total(), self.mesh_tiles_culled),
        };
    }
};

pub fn clearBytes(bytes: []u8) void {
    std.debug.assert(bytes.len >= @sizeOf(Snapshot));
    @memset(bytes[0..@sizeOf(Snapshot)], 0);
}

pub fn seedCpuMeshletPath(bytes: []align(@alignOf(u32)) u8, glyph_count: u32) void {
    std.debug.assert(bytes.len >= @sizeOf(Snapshot));
    const counters: *[counter_count]u32 = @ptrCast(bytes.ptr);
    counters[@intFromEnum(CounterIndex.task_glyphs_tested)] = glyph_count;
    counters[@intFromEnum(CounterIndex.task_glyphs_visible)] = glyph_count;
    counters[@intFromEnum(CounterIndex.task_glyphs_culled)] = 0;
}

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
    mesh_cull_accounted_per_mille: u32 = 0,
};

fn perMille(numerator: u32, denominator: u32) u32 {
    if (denominator == 0) return 0;
    return @intCast((@as(u64, numerator) * 1000) / denominator);
}

test "shader stats counter ABI is a packed u32 array" {
    try std.testing.expectEqual(@as(usize, counter_count * @sizeOf(u32)), @sizeOf(Snapshot));
    try std.testing.expectEqual(@as(u32, 23), @intFromEnum(CounterIndex.mesh_cull_non_finite));
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
    counters[@intFromEnum(CounterIndex.mesh_cull_empty_slices)] = 1;
    counters[@intFromEnum(CounterIndex.mesh_cull_invalid_strips)] = 2;
    counters[@intFromEnum(CounterIndex.mesh_cull_zero_area)] = 3;
    counters[@intFromEnum(CounterIndex.mesh_cull_clip_empty)] = 4;
    counters[@intFromEnum(CounterIndex.mesh_cull_non_finite)] = 5;

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
    const mesh_cull = snapshot.meshCullBreakdown();
    try std.testing.expectEqual(@as(u32, 1), mesh_cull.empty_slices);
    try std.testing.expectEqual(@as(u32, 2), mesh_cull.invalid_strips);
    try std.testing.expectEqual(@as(u32, 3), mesh_cull.zero_area);
    try std.testing.expectEqual(@as(u32, 4), mesh_cull.clip_empty);
    try std.testing.expectEqual(@as(u32, 5), mesh_cull.non_finite);
    try std.testing.expectEqual(@as(u32, 15), mesh_cull.total());
}

test "shader stats bytes helpers clear and decode counters" {
    var bytes: [@sizeOf(Snapshot)]u8 align(@alignOf(u32)) = undefined;
    @memset(&bytes, 0xaa);
    clearBytes(&bytes);

    const counters: *[counter_count]u32 = @ptrCast(&bytes);
    counters[@intFromEnum(CounterIndex.fragment_invocations)] = 7;
    counters[@intFromEnum(CounterIndex.mesh_tiles_emitted)] = 3;

    const snapshot = Snapshot.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u32, 7), snapshot.fragment_invocations);
    try std.testing.expectEqual(@as(u32, 3), snapshot.mesh_tiles_emitted);
}

test "shader stats seed CPU meshlet path visible glyph counters" {
    var bytes: [@sizeOf(Snapshot)]u8 align(@alignOf(u32)) = undefined;
    clearBytes(&bytes);
    seedCpuMeshletPath(&bytes, 42);

    const snapshot = Snapshot.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u32, 42), snapshot.task_glyphs_tested);
    try std.testing.expectEqual(@as(u32, 42), snapshot.task_glyphs_visible);
    try std.testing.expectEqual(@as(u32, 0), snapshot.task_glyphs_culled);
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
        .mesh_tiles_culled = 10,
        .mesh_cull_empty_slices = 2,
        .mesh_cull_invalid_strips = 3,
        .mesh_cull_clip_empty = 5,
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
    try std.testing.expectEqual(@as(u32, 1000), analysis_result.mesh_cull_accounted_per_mille);
}
