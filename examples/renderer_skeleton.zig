//! A backend-agnostic renderer skeleton. Copy this into your project and replace
//! the `backend.*` calls with your graphics API (raylib, sokol, wgpu, SDL, ...).
//!
//! `render` is generic over a duck-typed `backend`. The methods it expects:
//!
//!   fillRect(box, color, corner_radius)
//!   drawBorder(box, color, width, corner_radius)
//!   drawText(box, bytes, color, font_id, font_size, letter_spacing, line_height)
//!   drawImage(box, image_data, tint, corner_radius)
//!   pushClip(box, horizontal, vertical) / popClip()
//!   pushOverlay(color) / popOverlay()
//!   drawCustom(box, custom_data, background_color, corner_radius)
//!
//! Commands arrive pre-sorted in ascending z-order, so naive front-to-back
//! drawing is correct. `cmd.z_index` is exposed for batching renderers.

const std = @import("std");
const cl = @import("clay");

pub fn render(commands: []const cl.RenderCommand, backend: anytype) void {
    for (commands) |*cmd| {
        const box = cmd.bounding_box;
        switch (cmd.data()) {
            .none => {},
            .rectangle => |r| backend.fillRect(box, r.background_color, r.corner_radius),
            .border => |b| backend.drawBorder(box, b.color, b.width, b.corner_radius),
            .text => |t| backend.drawText(
                box,
                t.slice(),
                t.text_color,
                t.font_id,
                t.font_size,
                t.letter_spacing,
                t.line_height,
            ),
            .image => |im| backend.drawImage(box, im.image_data, im.background_color, im.corner_radius),
            .scissor_start => |c| backend.pushClip(box, c.horizontal, c.vertical),
            .scissor_end => backend.popClip(),
            .overlay_start => |o| backend.pushOverlay(o.color),
            .overlay_end => backend.popOverlay(),
            .custom => |c| backend.drawCustom(box, c.custom_data, c.background_color, c.corner_radius),
        }
    }
}

// --- A no-op backend so this file stays compile-checked by `zig build examples`. ---

const StubBackend = struct {
    fn fillRect(_: StubBackend, _: cl.BoundingBox, _: cl.Color, _: cl.CornerRadius) void {}
    fn drawBorder(_: StubBackend, _: cl.BoundingBox, _: cl.Color, _: cl.BorderWidth, _: cl.CornerRadius) void {}
    fn drawText(_: StubBackend, _: cl.BoundingBox, _: []const u8, _: cl.Color, _: u16, _: u16, _: u16, _: u16) void {}
    fn drawImage(_: StubBackend, _: cl.BoundingBox, _: ?*anyopaque, _: cl.Color, _: cl.CornerRadius) void {}
    fn pushClip(_: StubBackend, _: cl.BoundingBox, _: bool, _: bool) void {}
    fn popClip(_: StubBackend) void {}
    fn pushOverlay(_: StubBackend, _: cl.Color) void {}
    fn popOverlay(_: StubBackend) void {}
    fn drawCustom(_: StubBackend, _: cl.BoundingBox, _: ?*anyopaque, _: cl.Color, _: cl.CornerRadius) void {}
};

test "renderer skeleton compiles and handles every command type" {
    render(&.{}, StubBackend{});
}
