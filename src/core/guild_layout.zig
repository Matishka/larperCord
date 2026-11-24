//! Transformações da ordem de servidores e pastas do Discord.
const std = @import("std");
const types = @import("types.zig");
const Id = types.Id;

pub const Place = enum { before, after, inside };

pub const Target = union(enum) {
    guild: struct { id: Id, folder: u64 = 0 },
    folder: u64,
};

pub const MoveGuild = struct { guild: Id, target: Target, place: Place, new_id: u64 = 0 };
pub const MoveFolder = struct { folder: u64, target: Target, place: Place };

pub const Change = union(enum) {
    create: struct { first: Id, second: Id, id: u64 },
    move_guild: MoveGuild,
    move_folder: MoveFolder,
    rename: struct { folder: u64, name: []const u8 },
    color: struct { folder: u64, color: u32 },
    delete: u64,
};

fn freeOne(gpa: std.mem.Allocator, f: types.GuildFolder) void {
    gpa.free(f.name);
    gpa.free(f.guilds);
}

pub fn free(gpa: std.mem.Allocator, folders: []types.GuildFolder) void {
    for (folders) |f| freeOne(gpa, f);
    if (folders.len > 0) gpa.free(folders);
}

pub fn clone(gpa: std.mem.Allocator, folders: []const types.GuildFolder) error{OutOfMemory}![]types.GuildFolder {
    const out = try gpa.alloc(types.GuildFolder, folders.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |f| freeOne(gpa, f);
        if (out.len > 0) gpa.free(out);
    }
    for (folders) |f| {
        const name = try gpa.dupe(u8, f.name);
        errdefer gpa.free(name);
        const guilds = try gpa.dupe(Id, f.guilds);
        errdefer gpa.free(guilds);
        out[n] = .{ .id = f.id, .name = name, .color = f.color, .guilds = guilds };
        n += 1;
    }
    return out;
}

fn hasGuild(guilds: []const types.Guild, id: Id) bool {
    for (guilds) |g| if (g.id == id) return true;
    return false;
}

fn appendLoose(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), guild: Id) error{OutOfMemory}!void {
    const name = try gpa.dupe(u8, "");
    errdefer gpa.free(name);
    const ids = try gpa.alloc(Id, 1);
    ids[0] = guild;
    errdefer gpa.free(ids);
    try list.append(gpa, .{ .id = 0, .name = name, .color = 0, .guilds = ids });
}

fn appendFolder(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), f: types.GuildFolder) error{OutOfMemory}!void {
    const name = try gpa.dupe(u8, f.name);
    errdefer gpa.free(name);
    const ids = try gpa.dupe(Id, f.guilds);
    errdefer gpa.free(ids);
    try list.append(gpa, .{ .id = f.id, .name = name, .color = f.color, .guilds = ids });
}

/// Materializa servidores soltos como entradas id=0. Assim toda a ordem fica
/// explícita e pode ser enviada de volta ao Discord sem perder servidores novos.
fn normalize(gpa: std.mem.Allocator, guilds: []const types.Guild, current: []const types.GuildFolder) error{OutOfMemory}!std.ArrayList(types.GuildFolder) {
    var out: std.ArrayList(types.GuildFolder) = .empty;
    errdefer {
        for (out.items) |f| freeOne(gpa, f);
        out.deinit(gpa);
    }
    var listed: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer listed.deinit(gpa);
    var added: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer added.deinit(gpa);

    for (current) |f| for (f.guilds) |gid| {
        if (hasGuild(guilds, gid)) try listed.put(gpa, gid, {});
    };

    // O Store já põe servidores que acabaram de entrar antes da ordem recebida.
    for (guilds) |g| if (!listed.contains(g.id)) {
        try appendLoose(gpa, &out, g.id);
        try added.put(gpa, g.id, {});
    };

    for (current) |f| {
        if (f.id == 0) {
            for (f.guilds) |gid| {
                if (!hasGuild(guilds, gid) or added.contains(gid)) continue;
                try appendLoose(gpa, &out, gid);
                try added.put(gpa, gid, {});
            }
            continue;
        }
        var members: std.ArrayList(Id) = .empty;
        defer members.deinit(gpa);
        for (f.guilds) |gid| {
            if (!hasGuild(guilds, gid) or added.contains(gid)) continue;
            try members.append(gpa, gid);
            try added.put(gpa, gid, {});
        }
        if (members.items.len == 0) continue;
        try appendFolder(gpa, &out, .{ .id = f.id, .name = f.name, .color = f.color, .guilds = members.items });
    }
    return out;
}

fn folderIndex(list: []const types.GuildFolder, id: u64) ?usize {
    for (list, 0..) |f, i| if (f.id == id and id != 0) return i;
    return null;
}

fn guildIndex(list: []const types.GuildFolder, id: Id) ?usize {
    for (list, 0..) |f, i| {
        if (std.mem.indexOfScalar(Id, f.guilds, id) != null) return i;
    }
    return null;
}

fn targetIndex(list: []const types.GuildFolder, target: Target) ?usize {
    return switch (target) {
        .folder => |id| folderIndex(list, id),
        .guild => |g| if (g.folder != 0) folderIndex(list, g.folder) else guildIndex(list, g.id),
    };
}

fn insertFolder(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), index_in: usize, f: types.GuildFolder) error{OutOfMemory}!void {
    const index = @min(index_in, list.items.len);
    try list.append(gpa, f);
    var i = list.items.len - 1;
    while (i > index) : (i -= 1) list.items[i] = list.items[i - 1];
    list.items[index] = f;
}

fn removeFolderAt(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), index: usize) void {
    freeOne(gpa, list.items[index]);
    _ = list.orderedRemove(index);
}

fn removeGuild(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), guild: Id) error{OutOfMemory}!void {
    const index = guildIndex(list.items, guild) orelse return;
    const f = &list.items[index];
    if (f.id == 0 or f.guilds.len <= 1) {
        removeFolderAt(gpa, list, index);
        return;
    }
    const ids = try gpa.alloc(Id, f.guilds.len - 1);
    var n: usize = 0;
    for (f.guilds) |gid| if (gid != guild) {
        ids[n] = gid;
        n += 1;
    };
    gpa.free(f.guilds);
    f.guilds = ids;
}

fn appendMember(gpa: std.mem.Allocator, f: *types.GuildFolder, guild: Id) error{OutOfMemory}!void {
    const ids = try gpa.alloc(Id, f.guilds.len + 1);
    @memcpy(ids[0..f.guilds.len], f.guilds);
    ids[ids.len - 1] = guild;
    gpa.free(f.guilds);
    f.guilds = ids;
}

fn insertMember(gpa: std.mem.Allocator, f: *types.GuildFolder, guild: Id, target: Id, place: Place) error{OutOfMemory}!void {
    const at = std.mem.indexOfScalar(Id, f.guilds, target) orelse f.guilds.len;
    const index = @min(at + @as(usize, @intFromBool(place == .after)), f.guilds.len);
    const ids = try gpa.alloc(Id, f.guilds.len + 1);
    @memcpy(ids[0..index], f.guilds[0..index]);
    ids[index] = guild;
    @memcpy(ids[index + 1 ..], f.guilds[index..]);
    gpa.free(f.guilds);
    f.guilds = ids;
}

fn createFolder(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), first: Id, second: Id, id: u64) error{OutOfMemory, InvalidTarget}!void {
    if (first == second or id == 0 or folderIndex(list.items, id) != null) return error.InvalidTarget;
    const a = guildIndex(list.items, first) orelse return error.InvalidTarget;
    const b = guildIndex(list.items, second) orelse return error.InvalidTarget;
    const at = @min(a, b);
    try removeGuild(gpa, list, first);
    try removeGuild(gpa, list, second);
    const name = try gpa.dupe(u8, "");
    errdefer gpa.free(name);
    const ids = try gpa.alloc(Id, 2);
    ids[0] = first;
    ids[1] = second;
    errdefer gpa.free(ids);
    try insertFolder(gpa, list, at, .{ .id = id, .name = name, .color = 0, .guilds = ids });
}

fn insertLooseAt(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), index: usize, guild: Id) error{OutOfMemory}!void {
    const name = try gpa.dupe(u8, "");
    errdefer gpa.free(name);
    const ids = try gpa.alloc(Id, 1);
    ids[0] = guild;
    errdefer gpa.free(ids);
    try insertFolder(gpa, list, index, .{ .id = 0, .name = name, .color = 0, .guilds = ids });
}

fn moveGuild(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), change: MoveGuild) error{OutOfMemory, InvalidTarget}!void {
    const owner = guildIndex(list.items, change.guild) orelse return error.InvalidTarget;
    switch (change.place) {
        .inside => {
            const target_folder = switch (change.target) {
                .folder => |id| id,
                .guild => |g| blk: {
                    if (g.id == change.guild) return;
                    if (g.folder != 0) break :blk g.folder;
                    try createFolder(gpa, list, change.guild, g.id, change.new_id);
                    return;
                },
            };
            if (target_folder == 0) return error.InvalidTarget;
            if (folderIndex(list.items, target_folder) == null) return error.InvalidTarget;
            if (list.items[owner].id == target_folder) return;
            try removeGuild(gpa, list, change.guild);
            const fi = folderIndex(list.items, target_folder) orelse return error.InvalidTarget;
            try appendMember(gpa, &list.items[fi], change.guild);
        },
        .before, .after => {
            switch (change.target) {
                .guild => |g| {
                    if (g.id == change.guild) return;
                    if (g.folder != 0) {
                        try removeGuild(gpa, list, change.guild);
                        const fi = folderIndex(list.items, g.folder) orelse return error.InvalidTarget;
                        try insertMember(gpa, &list.items[fi], change.guild, g.id, change.place);
                        return;
                    }
                },
                .folder => |id| if (list.items[owner].id == id) return,
            }
            _ = targetIndex(list.items, change.target) orelse return error.InvalidTarget;
            try removeGuild(gpa, list, change.guild);
            const target_at = targetIndex(list.items, change.target) orelse return error.InvalidTarget;
            try insertLooseAt(gpa, list, target_at + @as(usize, @intFromBool(change.place == .after)), change.guild);
        },
    }
}

fn moveFolder(gpa: std.mem.Allocator, list: *std.ArrayList(types.GuildFolder), change: MoveFolder) error{OutOfMemory, InvalidTarget}!void {
    const source = folderIndex(list.items, change.folder) orelse return error.InvalidTarget;
    const target = targetIndex(list.items, change.target) orelse return error.InvalidTarget;
    if (source == target) return;
    if (change.target == .guild) {
        if (change.target.guild.folder == change.folder) return;
    }
    const moved = list.items[source];
    _ = list.orderedRemove(source);
    errdefer freeOne(gpa, moved);
    const target_after = targetIndex(list.items, change.target) orelse return error.InvalidTarget;
    const index = target_after + @as(usize, @intFromBool(change.place == .after));
    try insertFolder(gpa, list, index, moved);
}

pub fn apply(gpa: std.mem.Allocator, guilds: []const types.Guild, current: []const types.GuildFolder, change: Change) error{OutOfMemory, InvalidTarget}![]types.GuildFolder {
    var list = try normalize(gpa, guilds, current);
    errdefer {
        for (list.items) |f| freeOne(gpa, f);
        list.deinit(gpa);
    }
    switch (change) {
        .create => |c| try createFolder(gpa, &list, c.first, c.second, c.id),
        .move_guild => |m| try moveGuild(gpa, &list, m),
        .move_folder => |m| try moveFolder(gpa, &list, m),
        .rename => |r| {
            const i = folderIndex(list.items, r.folder) orelse return error.InvalidTarget;
            const name = try gpa.dupe(u8, r.name);
            gpa.free(list.items[i].name);
            list.items[i].name = name;
        },
        .color => |c| {
            const i = folderIndex(list.items, c.folder) orelse return error.InvalidTarget;
            list.items[i].color = c.color;
        },
        .delete => |id| {
            if (folderIndex(list.items, id) == null) return error.InvalidTarget;
            var replacement: std.ArrayList(types.GuildFolder) = .empty;
            errdefer {
                for (replacement.items) |f| freeOne(gpa, f);
                replacement.deinit(gpa);
            }
            for (list.items) |f| {
                if (f.id == id) {
                    for (f.guilds) |gid| try appendLoose(gpa, &replacement, gid);
                } else try appendFolder(gpa, &replacement, f);
            }
            for (list.items) |f| freeOne(gpa, f);
            list.deinit(gpa);
            list = replacement;
        },
    }
    return list.toOwnedSlice(gpa);
}

test "create, move into, rename, recolor and delete Discord folders" {
    const a = std.testing.allocator;
    const guilds = [_]types.Guild{
        .{ .id = 11, .name = "A", .acronym = "A" },
        .{ .id = 22, .name = "B", .acronym = "B" },
        .{ .id = 33, .name = "C", .acronym = "C" },
    };
    const initial = [_]types.GuildFolder{
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{11} },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{22} },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{33} },
    };
    const made = try apply(a, &guilds, &initial, .{ .create = .{ .first = 11, .second = 22, .id = 900 } });
    defer free(a, made);
    try std.testing.expectEqual(@as(usize, 2), made.len);
    try std.testing.expectEqual(@as(u64, 900), made[0].id);
    try std.testing.expectEqualSlices(Id, &.{ 11, 22 }, made[0].guilds);
    try std.testing.expectEqual(@as(Id, 33), made[1].guilds[0]);

    const moved = try apply(a, &guilds, made, .{ .move_guild = .{ .guild = 33, .target = .{ .folder = 900 }, .place = .inside } });
    defer free(a, moved);
    try std.testing.expectEqualSlices(Id, &.{ 11, 22, 33 }, moved[0].guilds);

    const renamed = try apply(a, &guilds, moved, .{ .rename = .{ .folder = 900, .name = "Games" } });
    defer free(a, renamed);
    try std.testing.expectEqualStrings("Games", renamed[0].name);

    const colored = try apply(a, &guilds, renamed, .{ .color = .{ .folder = 900, .color = 0x336699 } });
    defer free(a, colored);
    try std.testing.expectEqual(@as(u32, 0x336699), colored[0].color);

    const deleted = try apply(a, &guilds, colored, .{ .delete = 900 });
    defer free(a, deleted);
    try std.testing.expectEqual(@as(usize, 3), deleted.len);
    try std.testing.expectEqual(@as(u64, 0), deleted[0].id);
    try std.testing.expectEqual(@as(Id, 11), deleted[0].guilds[0]);
}

test "moving a server out of a folder and reordering folders preserves every guild" {
    const a = std.testing.allocator;
    const guilds = [_]types.Guild{
        .{ .id = 1, .name = "A", .acronym = "A" },
        .{ .id = 2, .name = "B", .acronym = "B" },
        .{ .id = 3, .name = "C", .acronym = "C" },
        .{ .id = 4, .name = "D", .acronym = "D" },
    };
    const current = [_]types.GuildFolder{
        .{ .id = 10, .name = "Games", .color = 0x123456, .guilds = &.{ 1, 2 } },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{3} },
        .{ .id = 20, .name = "Work", .color = 0, .guilds = &.{4} },
    };
    const moved = try apply(a, &guilds, &current, .{ .move_guild = .{
        .guild = 1,
        .target = .{ .guild = .{ .id = 3 } },
        .place = .after,
    } });
    defer free(a, moved);
    try std.testing.expectEqual(@as(usize, 4), moved.len);
    try std.testing.expectEqual(@as(u64, 10), moved[0].id);
    try std.testing.expectEqualSlices(Id, &.{2}, moved[0].guilds);
    try std.testing.expectEqual(@as(Id, 3), moved[1].guilds[0]);
    try std.testing.expectEqual(@as(Id, 1), moved[2].guilds[0]);
    try std.testing.expectEqual(@as(u64, 20), moved[3].id);

    const reordered = try apply(a, &guilds, moved, .{ .move_folder = .{
        .folder = 20,
        .target = .{ .folder = 10 },
        .place = .before,
    } });
    defer free(a, reordered);
    try std.testing.expectEqual(@as(u64, 20), reordered[0].id);
    try std.testing.expectEqual(@as(u64, 10), reordered[1].id);
    try std.testing.expectEqual(@as(Id, 3), reordered[2].guilds[0]);
    try std.testing.expectEqual(@as(Id, 1), reordered[3].guilds[0]);
}

test "dragging a server reorders it around another loose server" {
    const a = std.testing.allocator;
    const guilds = [_]types.Guild{
        .{ .id = 1, .name = "A", .acronym = "A" },
        .{ .id = 2, .name = "B", .acronym = "B" },
        .{ .id = 3, .name = "C", .acronym = "C" },
    };
    const current = [_]types.GuildFolder{
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{1} },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{2} },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{3} },
    };
    const moved = try apply(a, &guilds, &current, .{ .move_guild = .{
        .guild = 3,
        .target = .{ .guild = .{ .id = 1 } },
        .place = .before,
    } });
    defer free(a, moved);
    try std.testing.expectEqual(@as(Id, 3), moved[0].guilds[0]);
    try std.testing.expectEqual(@as(Id, 1), moved[1].guilds[0]);
}


test "creating a folder preserves unrelated existing folders" {
    const a = std.testing.allocator;
    const guilds = [_]types.Guild{
        .{ .id = 1, .name = "A", .acronym = "A" },
        .{ .id = 2, .name = "B", .acronym = "B" },
        .{ .id = 3, .name = "C", .acronym = "C" },
        .{ .id = 4, .name = "D", .acronym = "D" },
        .{ .id = 5, .name = "E", .acronym = "E" },
        .{ .id = 6, .name = "F", .acronym = "F" },
    };
    const current = [_]types.GuildFolder{
        .{ .id = 100, .name = "Friends", .color = 0x112233, .guilds = &.{ 1, 2 } },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{3} },
        .{ .id = 200, .name = "Work", .color = 0x445566, .guilds = &.{ 4, 5 } },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{6} },
    };
    const made = try apply(a, &guilds, &current, .{ .move_guild = .{
        .guild = 1,
        .target = .{ .guild = .{ .id = 6 } },
        .place = .inside,
        .new_id = 300,
    } });
    defer free(a, made);

    try std.testing.expectEqual(@as(usize, 4), made.len);
    try std.testing.expectEqual(@as(u64, 300), made[0].id);
    try std.testing.expectEqualSlices(Id, &.{ 1, 6 }, made[0].guilds);
    try std.testing.expectEqual(@as(u64, 100), made[1].id);
    try std.testing.expectEqualStrings("Friends", made[1].name);
    try std.testing.expectEqualSlices(Id, &.{2}, made[1].guilds);
    try std.testing.expectEqual(@as(u64, 0), made[2].id);
    try std.testing.expectEqualSlices(Id, &.{3}, made[2].guilds);
    try std.testing.expectEqual(@as(u64, 200), made[3].id);
    try std.testing.expectEqualStrings("Work", made[3].name);
    try std.testing.expectEqualSlices(Id, &.{ 4, 5 }, made[3].guilds);
}
