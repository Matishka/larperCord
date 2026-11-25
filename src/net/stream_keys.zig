//! Discord Go Live screen-share stream key decoding.
//! Pure parser: no network calls, no token handling, no side effects.
//! A stream is a separate RTC media session from the parent voice call.
const std = @import("std");
const Id = @import("../core/types.zig").Id;

pub const Kind = enum { guild, call, test };

pub const Key = struct {
    kind: Kind,
    guild: Id = 0,
    channel: Id = 0,
    owner: Id,

    pub fn belongsTo(self: Key, channel: Id) bool {
        return self.kind != .test and self.channel == channel;
    }
};

fn snowflake(value: []const u8) ?Id {
    if (value.len == 0) return null;
    const id = std.fmt.parseInt(Id, value, 10) catch return null;
    return if (id == 0) null else id;
}

/// Gateway stream_key formats:
///   guild:<guild_id>:<voice_channel_id>:<owner_id>
///   call:<dm_channel_id>:<owner_id>
///   test:<owner_id>
/// Reject malformed keys rather than guessing which media session they belong to.
pub fn parse(raw: []const u8) ?Key {
    var parts = std.mem.splitScalar(u8, raw, ':');
    const kind = parts.next() orelse return null;
    if (std.mem.eql(u8, kind, "guild")) {
        const guild = snowflake(parts.next() orelse return null) orelse return null;
        const channel = snowflake(parts.next() orelse return null) orelse return null;
        const owner = snowflake(parts.next() orelse return null) orelse return null;
        if (parts.next() != null) return null;
        return .{ .kind = .guild, .guild = guild, .channel = channel, .owner = owner };
    }
    if (std.mem.eql(u8, kind, "call")) {
        const channel = snowflake(parts.next() orelse return null) orelse return null;
        const owner = snowflake(parts.next() orelse return null) orelse return null;
        if (parts.next() != null) return null;
        return .{ .kind = .call, .channel = channel, .owner = owner };
    }
    if (std.mem.eql(u8, kind, "test")) {
        const owner = snowflake(parts.next() orelse return null) orelse return null;
        if (parts.next() != null) return null;
        return .{ .kind = .test, .owner = owner };
    }
    return null;
}

test "decode guild stream owner and voice channel" {
    const k = parse("guild:839502008108580904:850360749460553769:852892297661906993").?;
    try std.testing.expectEqual(Kind.guild, k.kind);
    try std.testing.expectEqual(@as(Id, 839502008108580904), k.guild);
    try std.testing.expectEqual(@as(Id, 850360749460553769), k.channel);
    try std.testing.expectEqual(@as(Id, 852892297661906993), k.owner);
    try std.testing.expect(k.belongsTo(850360749460553769));
    try std.testing.expect(!k.belongsTo(1));
}

test "decode direct call and test streams" {
    const dm = parse("call:1110739331624210483:852892297661906993").?;
    try std.testing.expectEqual(Kind.call, dm.kind);
    try std.testing.expectEqual(@as(Id, 0), dm.guild);
    try std.testing.expectEqual(@as(Id, 1110739331624210483), dm.channel);
    try std.testing.expect(dm.belongsTo(dm.channel));

    const probe = parse("test:852892297661906993").?;
    try std.testing.expectEqual(Kind.test, probe.kind);
    try std.testing.expect(!probe.belongsTo(0));
}

test "reject invalid or ambiguous stream keys" {
    for ([_][]const u8{
        "", "guild", "guild:1:2", "guild:1:2:3:4",
        "guild:0:2:3", "guild:1:0:3", "guild:1:2:0",
        "guild:1:hello:3", "guild:-1:2:3",
        "call:1", "call:1:2:3", "call:1:0",
        "test:", "test:1:2", "unknown:1:2:3",
        "guild:18446744073709551616:2:3",
    }) |bad| {
        try std.testing.expect(parse(bad) == null);
    }
}
