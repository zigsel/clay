//! Compile-time ABI conformance: every idiomatic type in `root.zig` is checked
//! against the real `clay.h` for matching size, alignment and field offsets. If
//! clay.h ever changes layout, `zig build test` fails loudly here instead of
//! silently corrupting memory at runtime.
//!
//! The C side comes from `b.addTranslateC` in build.zig (the 0.16 build-graph
//! replacement for `@cImport`), wired in as the `clay_h` import.

const std = @import("std");
const cl = @import("root.zig");

const c = @import("clay_h");

fn expectLayout(comptime Zig: type, comptime C: type) void {
    if (@sizeOf(Zig) != @sizeOf(C)) @compileError(std.fmt.comptimePrint(
        "ABI size mismatch: {s} = {d} bytes, but C {s} = {d} bytes",
        .{ @typeName(Zig), @sizeOf(Zig), @typeName(C), @sizeOf(C) },
    ));
    if (@alignOf(Zig) != @alignOf(C)) @compileError(std.fmt.comptimePrint(
        "ABI align mismatch: {s} = {d}, but C {s} = {d}",
        .{ @typeName(Zig), @alignOf(Zig), @typeName(C), @alignOf(C) },
    ));
}

/// Check a list of `.{ "zig_field", "cField" }` offset pairs match.
fn expectOffsets(comptime Zig: type, comptime C: type, comptime pairs: anytype) void {
    inline for (pairs) |pair| {
        const zo = @offsetOf(Zig, pair[0]);
        const co = @offsetOf(C, pair[1]);
        if (zo != co) @compileError(std.fmt.comptimePrint(
            "ABI offset mismatch: {s}.{s}@{d} vs C {s}.{s}@{d}",
            .{ @typeName(Zig), pair[0], zo, @typeName(C), pair[1], co },
        ));
    }
}

test "struct sizes and alignments match clay.h" {
    expectLayout(cl.String, c.Clay_String);
    expectLayout(cl.StringSlice, c.Clay_StringSlice);
    expectLayout(cl.Arena, c.Clay_Arena);
    expectLayout(cl.Dimensions, c.Clay_Dimensions);
    expectLayout(cl.Vector2, c.Clay_Vector2);
    expectLayout(cl.Color, c.Clay_Color);
    expectLayout(cl.BoundingBox, c.Clay_BoundingBox);
    expectLayout(cl.ElementId, c.Clay_ElementId);
    expectLayout(cl.ElementIdArray, c.Clay_ElementIdArray);
    expectLayout(cl.CornerRadius, c.Clay_CornerRadius);

    expectLayout(cl.SizingMinMax, c.Clay_SizingMinMax);
    expectLayout(cl.SizingAxis, c.Clay_SizingAxis);
    expectLayout(cl.Sizing, c.Clay_Sizing);
    expectLayout(cl.Padding, c.Clay_Padding);
    expectLayout(cl.ChildAlignment, c.Clay_ChildAlignment);
    expectLayout(cl.LayoutConfig, c.Clay_LayoutConfig);

    expectLayout(cl.TextConfig, c.Clay_TextElementConfig);
    expectLayout(cl.AspectRatioConfig, c.Clay_AspectRatioElementConfig);
    expectLayout(cl.ImageConfig, c.Clay_ImageElementConfig);
    expectLayout(cl.FloatingAttachPoints, c.Clay_FloatingAttachPoints);
    expectLayout(cl.FloatingConfig, c.Clay_FloatingElementConfig);
    expectLayout(cl.CustomConfig, c.Clay_CustomElementConfig);
    expectLayout(cl.ClipConfig, c.Clay_ClipElementConfig);
    expectLayout(cl.BorderWidth, c.Clay_BorderWidth);
    expectLayout(cl.BorderConfig, c.Clay_BorderElementConfig);

    expectLayout(cl.TransitionData, c.Clay_TransitionData);
    expectLayout(cl.TransitionCallbackArguments, c.Clay_TransitionCallbackArguments);
    expectLayout(cl.TransitionConfig, c.Clay_TransitionElementConfig);
    expectLayout(cl.TransitionProperty, c.Clay_TransitionProperty);

    expectLayout(cl.ElementDeclaration, c.Clay_ElementDeclaration);

    expectLayout(cl.RectangleData, c.Clay_RectangleRenderData);
    expectLayout(cl.TextData, c.Clay_TextRenderData);
    expectLayout(cl.ImageData, c.Clay_ImageRenderData);
    expectLayout(cl.CustomData, c.Clay_CustomRenderData);
    expectLayout(cl.ClipData, c.Clay_ClipRenderData);
    expectLayout(cl.OverlayData, c.Clay_OverlayColorRenderData);
    expectLayout(cl.BorderData, c.Clay_BorderRenderData);
    expectLayout(cl.RenderDataRaw, c.Clay_RenderData);
    expectLayout(cl.RenderCommand, c.Clay_RenderCommand);
    expectLayout(cl.RenderCommandArray, c.Clay_RenderCommandArray);

    expectLayout(cl.PointerData, c.Clay_PointerData);
    expectLayout(cl.ScrollContainerData, c.Clay_ScrollContainerData);
    expectLayout(cl.ElementData, c.Clay_ElementData);
    expectLayout(cl.ErrorData, c.Clay_ErrorData);
    expectLayout(cl.ErrorHandler, c.Clay_ErrorHandler);
}

test "field offsets match clay.h for layout-fragile aggregates" {
    expectOffsets(cl.String, c.Clay_String, .{
        .{ "is_statically_allocated", "isStaticallyAllocated" },
        .{ "length", "length" },
        .{ "chars", "chars" },
    });
    expectOffsets(cl.LayoutConfig, c.Clay_LayoutConfig, .{
        .{ "sizing", "sizing" },
        .{ "padding", "padding" },
        .{ "child_gap", "childGap" },
        .{ "child_alignment", "childAlignment" },
        .{ "direction", "layoutDirection" },
    });
    expectOffsets(cl.TextConfig, c.Clay_TextElementConfig, .{
        .{ "user_data", "userData" },
        .{ "color", "textColor" },
        .{ "font_id", "fontId" },
        .{ "font_size", "fontSize" },
        .{ "letter_spacing", "letterSpacing" },
        .{ "line_height", "lineHeight" },
        .{ "wrap_mode", "wrapMode" },
        .{ "alignment", "textAlignment" },
    });
    expectOffsets(cl.FloatingConfig, c.Clay_FloatingElementConfig, .{
        .{ "offset", "offset" },
        .{ "expand", "expand" },
        .{ "parent_id", "parentId" },
        .{ "z_index", "zIndex" },
        .{ "attach_points", "attachPoints" },
        .{ "pointer_capture_mode", "pointerCaptureMode" },
        .{ "attach_to", "attachTo" },
        .{ "clip_to", "clipTo" },
    });
    expectOffsets(cl.ElementDeclaration, c.Clay_ElementDeclaration, .{
        .{ "layout", "layout" },
        .{ "background_color", "backgroundColor" },
        .{ "overlay_color", "overlayColor" },
        .{ "corner_radius", "cornerRadius" },
        .{ "aspect_ratio", "aspectRatio" },
        .{ "image", "image" },
        .{ "floating", "floating" },
        .{ "custom", "custom" },
        .{ "clip", "clip" },
        .{ "border", "border" },
        .{ "transition", "transition" },
        .{ "user_data", "userData" },
    });
    expectOffsets(cl.RenderCommand, c.Clay_RenderCommand, .{
        .{ "bounding_box", "boundingBox" },
        .{ "render_data", "renderData" },
        .{ "user_data", "userData" },
        .{ "id", "id" },
        .{ "z_index", "zIndex" },
        .{ "command_type", "commandType" },
    });
    expectOffsets(cl.ScrollContainerData, c.Clay_ScrollContainerData, .{
        .{ "scroll_position", "scrollPosition" },
        .{ "scroll_container_dimensions", "scrollContainerDimensions" },
        .{ "content_dimensions", "contentDimensions" },
        .{ "config", "config" },
        .{ "found", "found" },
    });
    expectOffsets(cl.TransitionCallbackArguments, c.Clay_TransitionCallbackArguments, .{
        .{ "transition_state", "transitionState" },
        .{ "initial", "initial" },
        .{ "current", "current" },
        .{ "target", "target" },
        .{ "elapsed_time", "elapsedTime" },
        .{ "duration", "duration" },
        .{ "properties", "properties" },
    });
}

test "enum values match clay.h" {
    try std.testing.expectEqual(@as(c_int, c.CLAY_RENDER_COMMAND_TYPE_CUSTOM), @intFromEnum(cl.RenderCommandType.custom));
    try std.testing.expectEqual(@as(c_int, c.CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START), @intFromEnum(cl.RenderCommandType.overlay_color_start));
    try std.testing.expectEqual(@as(c_int, c.CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED), @intFromEnum(cl.ErrorType.hash_map_capacity_exceeded));
    try std.testing.expectEqual(@as(c_int, c.CLAY_ATTACH_TO_ROOT), @intFromEnum(cl.FloatingAttachToElement.root));
    try std.testing.expectEqual(@as(c_int, c.CLAY__SIZING_TYPE_FIXED), @intFromEnum(cl.SizingType.fixed));
    try std.testing.expectEqual(@as(c_int, c.CLAY_TRANSITION_PROPERTY_BORDER_WIDTH), @as(i32, @bitCast(cl.TransitionProperty{ .border_width = true })));
}
