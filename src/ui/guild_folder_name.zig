//! Renomear uma pasta de servidores do Dock.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const types = @import("../core/types.zig");
const popup = @import("popup.zig");
const forum = @import("forum.zig");
const inbox = @import("inbox.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");

var name_buf: [97]u8 = @splat(0);

pub fn open(ctx: *d.Ctx, id: u64) void {
    @memset(&name_buf, 0);
    for (ctx.store.folders) |f| if (f.id == id) {
        const n = @min(f.name.len, name_buf.len - 1);
        @memcpy(name_buf[0..n], f.name[0..n]);
        break;
    };
    ctx.popup(.{ .guild_folder_name = .{ .id = id } });
}

pub fn draw(ctx: *d.Ctx, id: u64) void {
    var found: ?*const types.GuildFolder = null;
    for (ctx.store.folders) |*f| if (f.id == id) {
        found = f;
        break;
    };
    if (found == null) return popup.close(ctx);

    const r = forum.dialogRect(ctx, 430, 188);
    const dl = popup.beginWindow("##guild-folder-name", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    d.rect(dl, .{ .x = r.x + 18, .y = r.y + 17, .w = 22, .h = 7 }, ctx.col(.accent), 3);
    d.rect(dl, .{ .x = r.x + 18, .y = r.y + 23, .w = 28, .h = 17 }, ctx.col(.accent).mix(ctx.col(.text), 0.12), 4);
    d.text(dl, fam.get(.bold), 17, r.x + 56, r.y + 16, ctx.col(.text), i18n.tr("Renomear pasta", "Rename folder"));
    _ = d.textClipped(dl, fam.get(.regular), 13, r.x + 18, r.y + 48, ctx.col(.muted), i18n.tr("O nome será sincronizado com sua conta Discord.", "The name will sync with your Discord account."), r.w - 36);

    const ir: d.Rect = .{ .x = r.x + 18, .y = r.y + 80, .w = r.w - 36, .h = 36 };
    qa.mark(ir, "guild-folder-name", .{});
    if (popup.appearing) c.ImGui_SetKeyboardFocusHere();
    const enter = forum.textInput(ctx, dl, ir, "##guild-folder-name-input", i18n.trZ("Nome da pasta", "Folder name").ptr, &name_buf, c.ImGuiInputTextFlags_EnterReturnsTrue);
    const name = std.mem.trim(u8, std.mem.sliceTo(&name_buf, 0), " \t\r\n");
    const valid = name.len <= 96 and std.unicode.utf8ValidateSlice(name);

    const save_label = i18n.tr("Salvar", "Save");
    const cancel_label = i18n.tr("Cancelar", "Cancel");
    const save_w = inbox.buttonWidth(ctx, save_label);
    const cancel_w = inbox.buttonWidth(ctx, cancel_label);
    const save_r: d.Rect = .{ .x = r.right() - 18 - save_w, .y = r.bottom() - 48, .w = save_w, .h = 32 };
    const cancel_r: d.Rect = .{ .x = save_r.x - 8 - cancel_w, .y = save_r.y, .w = cancel_w, .h = 32 };
    const save = forum.primary(ctx, dl, fam, 710, save_r, save_label, valid);
    const cancel = inbox.button(ctx, dl, 711, cancel_r, cancel_label, false);
    if (cancel) return popup.close(ctx);
    if (save or (enter and valid)) {
        const owned = ctx.st.gpa.dupe(u8, name) catch return;
        ctx.act(.{ .guild_layout = .{ .rename = .{ .folder = id, .name = owned } } });
        popup.close(ctx);
    }
}
