//! Shared helpers for project-owned wire and ABI protocol identifiers.

const std = @import("std");

pub const ProtocolVersion = struct {
    major: u16,
    minor: u16,

    pub fn init(major: u16, minor: u16) ProtocolVersion {
        return .{ .major = major, .minor = minor };
    }

    pub fn fromWord(word_value: u32) ProtocolVersion {
        return .{
            .major = @intCast(word_value >> 16),
            .minor = @intCast(word_value & 0xffff),
        };
    }

    pub fn word(self: ProtocolVersion) u32 {
        return (@as(u32, self.major) << 16) | @as(u32, self.minor);
    }

    pub fn matches(self: ProtocolVersion, word_value: u32) bool {
        return self.word() == word_value;
    }
};

pub fn magicWord(comptime tag: []const u8) u32 {
    comptime {
        if (tag.len != 4) @compileError("protocol magic words must be exactly four ASCII bytes");
    }
    return @as(u32, tag[0]) |
        (@as(u32, tag[1]) << 8) |
        (@as(u32, tag[2]) << 16) |
        (@as(u32, tag[3]) << 24);
}

test "ProtocolVersion: packs major and minor into one ABI word" {
    const version = ProtocolVersion.init(4, 2);
    try std.testing.expectEqual(@as(u32, 0x0004_0002), version.word());
    try std.testing.expectEqual(version, ProtocolVersion.fromWord(version.word()));
    try std.testing.expect(version.matches(0x0004_0002));
}

test "magicWord: stores ASCII tags in little-endian word order" {
    try std.testing.expectEqual(@as(u32, 0x4c42_5348), magicWord("HSBL"));
}
