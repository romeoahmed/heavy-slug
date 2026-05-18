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
    submitted_glyphs = 6,
    submitted_meshlets = 7,
    draw_chunks = 8,
    frame_submissions = 9,
    mesh_workgroups = 10,
    candidate_curve_bbox_rejects = 11,
    full_scan_curve_bbox_rejects = 12,
    candidate_curve_integrations = 13,
    full_scan_curve_integrations = 14,
    bbox_empty_fragments = 15,
    coverage_zero_fragments = 16,
    meshlets_emitted = 17,
    meshlets_culled = 18,
    meshlet_cull_empty_slices = 19,
    meshlet_cull_invalid_strips = 20,
    meshlet_cull_zero_area = 21,
    meshlet_cull_clip_empty = 22,
    meshlet_cull_non_finite = 23,
};

pub const MeshletCull = struct {
    empty_slices: u32 = 0,
    invalid_strips: u32 = 0,
    zero_area: u32 = 0,
    clip_empty: u32 = 0,
    non_finite: u32 = 0,

    pub fn total(self: MeshletCull) u32 {
        return self.empty_slices +
            self.invalid_strips +
            self.zero_area +
            self.clip_empty +
            self.non_finite;
    }
};

/// Stats copied from the shader counter buffer.
pub const Stats = extern struct {
    fragment_invocations: u32 = 0,
    candidate_path_fragments: u32 = 0,
    full_scan_fragments: u32 = 0,
    candidate_curve_tests: u32 = 0,
    full_scan_curve_tests: u32 = 0,
    empty_fragments: u32 = 0,
    submitted_glyphs: u32 = 0,
    submitted_meshlets: u32 = 0,
    draw_chunks: u32 = 0,
    frame_submissions: u32 = 0,
    mesh_workgroups: u32 = 0,
    candidate_curve_bbox_rejects: u32 = 0,
    full_scan_curve_bbox_rejects: u32 = 0,
    candidate_curve_integrations: u32 = 0,
    full_scan_curve_integrations: u32 = 0,
    bbox_empty_fragments: u32 = 0,
    coverage_zero_fragments: u32 = 0,
    meshlets_emitted: u32 = 0,
    meshlets_culled: u32 = 0,
    meshlet_cull_empty_slices: u32 = 0,
    meshlet_cull_invalid_strips: u32 = 0,
    meshlet_cull_zero_area: u32 = 0,
    meshlet_cull_clip_empty: u32 = 0,
    meshlet_cull_non_finite: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn fromCounters(counters: *const [counter_count]u32) Stats {
        return .{
            .fragment_invocations = counters[@intFromEnum(CounterIndex.fragment_invocations)],
            .candidate_path_fragments = counters[@intFromEnum(CounterIndex.candidate_path_fragments)],
            .full_scan_fragments = counters[@intFromEnum(CounterIndex.full_scan_fragments)],
            .candidate_curve_tests = counters[@intFromEnum(CounterIndex.candidate_curve_tests)],
            .full_scan_curve_tests = counters[@intFromEnum(CounterIndex.full_scan_curve_tests)],
            .empty_fragments = counters[@intFromEnum(CounterIndex.empty_fragments)],
            .submitted_glyphs = counters[@intFromEnum(CounterIndex.submitted_glyphs)],
            .submitted_meshlets = counters[@intFromEnum(CounterIndex.submitted_meshlets)],
            .draw_chunks = counters[@intFromEnum(CounterIndex.draw_chunks)],
            .frame_submissions = counters[@intFromEnum(CounterIndex.frame_submissions)],
            .mesh_workgroups = counters[@intFromEnum(CounterIndex.mesh_workgroups)],
            .candidate_curve_bbox_rejects = counters[@intFromEnum(CounterIndex.candidate_curve_bbox_rejects)],
            .full_scan_curve_bbox_rejects = counters[@intFromEnum(CounterIndex.full_scan_curve_bbox_rejects)],
            .candidate_curve_integrations = counters[@intFromEnum(CounterIndex.candidate_curve_integrations)],
            .full_scan_curve_integrations = counters[@intFromEnum(CounterIndex.full_scan_curve_integrations)],
            .bbox_empty_fragments = counters[@intFromEnum(CounterIndex.bbox_empty_fragments)],
            .coverage_zero_fragments = counters[@intFromEnum(CounterIndex.coverage_zero_fragments)],
            .meshlets_emitted = counters[@intFromEnum(CounterIndex.meshlets_emitted)],
            .meshlets_culled = counters[@intFromEnum(CounterIndex.meshlets_culled)],
            .meshlet_cull_empty_slices = counters[@intFromEnum(CounterIndex.meshlet_cull_empty_slices)],
            .meshlet_cull_invalid_strips = counters[@intFromEnum(CounterIndex.meshlet_cull_invalid_strips)],
            .meshlet_cull_zero_area = counters[@intFromEnum(CounterIndex.meshlet_cull_zero_area)],
            .meshlet_cull_clip_empty = counters[@intFromEnum(CounterIndex.meshlet_cull_clip_empty)],
            .meshlet_cull_non_finite = counters[@intFromEnum(CounterIndex.meshlet_cull_non_finite)],
        };
    }

    pub fn fromBytes(bytes: []align(@alignOf(u32)) const u8) Stats {
        std.debug.assert(bytes.len >= @sizeOf(Stats));
        const counters: *const [counter_count]u32 = @ptrCast(bytes.ptr);
        return fromCounters(counters);
    }

    pub fn totalCurveTests(self: Stats) u32 {
        return self.candidate_curve_tests + self.full_scan_curve_tests;
    }

    pub fn totalCurveBboxRejects(self: Stats) u32 {
        return self.candidate_curve_bbox_rejects + self.full_scan_curve_bbox_rejects;
    }

    pub fn totalCurveIntegrations(self: Stats) u32 {
        return self.candidate_curve_integrations + self.full_scan_curve_integrations;
    }

    pub fn meshletCull(self: Stats) MeshletCull {
        return .{
            .empty_slices = self.meshlet_cull_empty_slices,
            .invalid_strips = self.meshlet_cull_invalid_strips,
            .zero_area = self.meshlet_cull_zero_area,
            .clip_empty = self.meshlet_cull_clip_empty,
            .non_finite = self.meshlet_cull_non_finite,
        };
    }

    pub fn ratios(self: Stats) Ratios {
        return .{
            .full_scan_fragment_per_mille = perMille(self.full_scan_fragments, self.fragment_invocations),
            .bbox_reject_per_mille = perMille(self.totalCurveBboxRejects(), self.totalCurveTests()),
            .bbox_empty_fragment_per_mille = perMille(self.bbox_empty_fragments, self.fragment_invocations),
            .coverage_zero_fragment_per_mille = perMille(self.coverage_zero_fragments, self.fragment_invocations),
            .fragments_per_glyph_milli = perMille(self.fragment_invocations, self.submitted_glyphs),
            .fragments_per_meshlet_milli = perMille(self.fragment_invocations, self.meshlets_emitted),
            .meshlets_per_glyph_milli = perMille(self.submitted_meshlets, self.submitted_glyphs),
            .curve_tests_per_fragment_milli = perMille(self.totalCurveTests(), self.fragment_invocations),
            .curve_integrations_per_fragment_milli = perMille(self.totalCurveIntegrations(), self.fragment_invocations),
            .meshlet_cull_accounted_per_mille = perMille(self.meshletCull().total(), self.meshlets_culled),
        };
    }
};

pub fn clearBytes(bytes: []u8) void {
    std.debug.assert(bytes.len >= @sizeOf(Stats));
    @memset(bytes[0..@sizeOf(Stats)], 0);
}

pub fn seedFrameSubmission(
    bytes: []align(@alignOf(u32)) u8,
    glyph_count: u32,
    meshlet_count: u32,
    draw_chunks: u32,
) void {
    std.debug.assert(bytes.len >= @sizeOf(Stats));
    const counters: *[counter_count]u32 = @ptrCast(bytes.ptr);
    counters[@intFromEnum(CounterIndex.submitted_glyphs)] = glyph_count;
    counters[@intFromEnum(CounterIndex.submitted_meshlets)] = meshlet_count;
    counters[@intFromEnum(CounterIndex.draw_chunks)] = draw_chunks;
    counters[@intFromEnum(CounterIndex.frame_submissions)] = 1;
}

/// Integer ratios scaled by 1000 for stable debug logging.
pub const Ratios = struct {
    full_scan_fragment_per_mille: u32 = 0,
    bbox_reject_per_mille: u32 = 0,
    bbox_empty_fragment_per_mille: u32 = 0,
    coverage_zero_fragment_per_mille: u32 = 0,
    fragments_per_glyph_milli: u32 = 0,
    fragments_per_meshlet_milli: u32 = 0,
    meshlets_per_glyph_milli: u32 = 0,
    curve_tests_per_fragment_milli: u32 = 0,
    curve_integrations_per_fragment_milli: u32 = 0,
    meshlet_cull_accounted_per_mille: u32 = 0,
};

fn perMille(numerator: u32, denominator: u32) u32 {
    if (denominator == 0) return 0;
    return @intCast((@as(u64, numerator) * 1000) / denominator);
}

test "shader stats counter ABI is a packed u32 array" {
    try std.testing.expectEqual(@as(usize, counter_count * @sizeOf(u32)), @sizeOf(Stats));
    try std.testing.expectEqual(@as(u32, 23), @intFromEnum(CounterIndex.meshlet_cull_non_finite));
}

test "shader stats maps submitted glyph and meshlet counters" {
    var counters = [_]u32{0} ** counter_count;
    counters[@intFromEnum(CounterIndex.submitted_glyphs)] = 60;
    counters[@intFromEnum(CounterIndex.submitted_meshlets)] = 96;
    counters[@intFromEnum(CounterIndex.draw_chunks)] = 3;
    counters[@intFromEnum(CounterIndex.frame_submissions)] = 1;
    counters[@intFromEnum(CounterIndex.mesh_workgroups)] = 60;
    counters[@intFromEnum(CounterIndex.candidate_curve_bbox_rejects)] = 400;
    counters[@intFromEnum(CounterIndex.full_scan_curve_bbox_rejects)] = 12;
    counters[@intFromEnum(CounterIndex.candidate_curve_integrations)] = 500;
    counters[@intFromEnum(CounterIndex.full_scan_curve_integrations)] = 8;
    counters[@intFromEnum(CounterIndex.bbox_empty_fragments)] = 20;
    counters[@intFromEnum(CounterIndex.coverage_zero_fragments)] = 30;
    counters[@intFromEnum(CounterIndex.meshlets_emitted)] = 44;
    counters[@intFromEnum(CounterIndex.meshlets_culled)] = 16;
    counters[@intFromEnum(CounterIndex.meshlet_cull_empty_slices)] = 1;
    counters[@intFromEnum(CounterIndex.meshlet_cull_invalid_strips)] = 2;
    counters[@intFromEnum(CounterIndex.meshlet_cull_zero_area)] = 3;
    counters[@intFromEnum(CounterIndex.meshlet_cull_clip_empty)] = 4;
    counters[@intFromEnum(CounterIndex.meshlet_cull_non_finite)] = 5;

    const snapshot = Stats.fromCounters(&counters);
    try std.testing.expectEqual(@as(u32, 60), snapshot.submitted_glyphs);
    try std.testing.expectEqual(@as(u32, 96), snapshot.submitted_meshlets);
    try std.testing.expectEqual(@as(u32, 3), snapshot.draw_chunks);
    try std.testing.expectEqual(@as(u32, 1), snapshot.frame_submissions);
    try std.testing.expectEqual(@as(u32, 60), snapshot.mesh_workgroups);
    try std.testing.expectEqual(@as(u32, 400), snapshot.candidate_curve_bbox_rejects);
    try std.testing.expectEqual(@as(u32, 12), snapshot.full_scan_curve_bbox_rejects);
    try std.testing.expectEqual(@as(u32, 500), snapshot.candidate_curve_integrations);
    try std.testing.expectEqual(@as(u32, 8), snapshot.full_scan_curve_integrations);
    try std.testing.expectEqual(@as(u32, 20), snapshot.bbox_empty_fragments);
    try std.testing.expectEqual(@as(u32, 30), snapshot.coverage_zero_fragments);
    try std.testing.expectEqual(@as(u32, 44), snapshot.meshlets_emitted);
    try std.testing.expectEqual(@as(u32, 16), snapshot.meshlets_culled);
    const meshlet_cull = snapshot.meshletCull();
    try std.testing.expectEqual(@as(u32, 1), meshlet_cull.empty_slices);
    try std.testing.expectEqual(@as(u32, 2), meshlet_cull.invalid_strips);
    try std.testing.expectEqual(@as(u32, 3), meshlet_cull.zero_area);
    try std.testing.expectEqual(@as(u32, 4), meshlet_cull.clip_empty);
    try std.testing.expectEqual(@as(u32, 5), meshlet_cull.non_finite);
    try std.testing.expectEqual(@as(u32, 15), meshlet_cull.total());
}

test "shader stats bytes helpers clear and decode counters" {
    var bytes: [@sizeOf(Stats)]u8 align(@alignOf(u32)) = undefined;
    @memset(&bytes, 0xaa);
    clearBytes(&bytes);

    const counters: *[counter_count]u32 = @ptrCast(&bytes);
    counters[@intFromEnum(CounterIndex.fragment_invocations)] = 7;
    counters[@intFromEnum(CounterIndex.meshlets_emitted)] = 3;

    const snapshot = Stats.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u32, 7), snapshot.fragment_invocations);
    try std.testing.expectEqual(@as(u32, 3), snapshot.meshlets_emitted);
}

test "shader stats seed frame submission counters" {
    var bytes: [@sizeOf(Stats)]u8 align(@alignOf(u32)) = undefined;
    clearBytes(&bytes);
    seedFrameSubmission(&bytes, 42, 99, 2);

    const snapshot = Stats.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u32, 42), snapshot.submitted_glyphs);
    try std.testing.expectEqual(@as(u32, 99), snapshot.submitted_meshlets);
    try std.testing.expectEqual(@as(u32, 2), snapshot.draw_chunks);
    try std.testing.expectEqual(@as(u32, 1), snapshot.frame_submissions);
}

test "shader stats ratios derive bottleneck rates" {
    const snapshot = Stats{
        .fragment_invocations = 100,
        .full_scan_fragments = 25,
        .candidate_curve_tests = 200,
        .full_scan_curve_tests = 100,
        .submitted_glyphs = 20,
        .submitted_meshlets = 40,
        .meshlets_emitted = 25,
        .meshlets_culled = 10,
        .meshlet_cull_empty_slices = 2,
        .meshlet_cull_invalid_strips = 3,
        .meshlet_cull_clip_empty = 5,
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

    const ratios = snapshot.ratios();
    try std.testing.expectEqual(@as(u32, 250), ratios.full_scan_fragment_per_mille);
    try std.testing.expectEqual(@as(u32, 600), ratios.bbox_reject_per_mille);
    try std.testing.expectEqual(@as(u32, 100), ratios.bbox_empty_fragment_per_mille);
    try std.testing.expectEqual(@as(u32, 150), ratios.coverage_zero_fragment_per_mille);
    try std.testing.expectEqual(@as(u32, 5000), ratios.fragments_per_glyph_milli);
    try std.testing.expectEqual(@as(u32, 4000), ratios.fragments_per_meshlet_milli);
    try std.testing.expectEqual(@as(u32, 2000), ratios.meshlets_per_glyph_milli);
    try std.testing.expectEqual(@as(u32, 3000), ratios.curve_tests_per_fragment_milli);
    try std.testing.expectEqual(@as(u32, 1200), ratios.curve_integrations_per_fragment_milli);
    try std.testing.expectEqual(@as(u32, 1000), ratios.meshlet_cull_accounted_per_mille);
}
