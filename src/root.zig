//! Idiomatic Zig bindings for Clay (https://github.com/nicbarker/clay), tracking `main`.
//!
//! Design:
//!  - Native Zig `extern struct` types with sensible defaults and constructor
//!    helpers usable as decl literals (`.grow`, `.all(16)`, `.rgb(...)`).
//!  - `defer`-guarded layout DSL: `const e = cl.open(.{...}); defer e.end();`,
//!    nesting children inside an ordinary Zig block scope.
//!  - Render commands are consumed as a Zig tagged union via `cmd.data()`.
//!  - Every struct is ABI-checked against the real clay.h at build time
//!    (see `src/abi_verify.zig`, run by `zig build test`).
//!
//! Pinned clay commit: e6cc36941ab2af5d81107617039d6f527a1c660b (VERSION 0.14 + main).

const std = @import("std");

// =============================================================================
// Core value types
// =============================================================================

pub const Context = opaque {};

/// A length-delimited string. Not guaranteed to be null-terminated.
pub const String = extern struct {
    /// Set when the underlying bytes live for the whole program (enables caching).
    is_statically_allocated: bool = false,
    length: i32 = 0,
    chars: [*]const u8 = "",

    pub fn fromSlice(s: []const u8) String {
        return .{ .is_statically_allocated = false, .length = @intCast(s.len), .chars = s.ptr };
    }
    pub fn fromComptime(comptime s: []const u8) String {
        return .{ .is_statically_allocated = true, .length = @intCast(s.len), .chars = s.ptr };
    }
    pub fn slice(self: String) []const u8 {
        return self.chars[0..@intCast(self.length)];
    }
};

/// A non-owning slice into a source string. Yielded to renderers for text.
pub const StringSlice = extern struct {
    length: i32 = 0,
    chars: [*]const u8 = "",
    base_chars: [*]const u8 = "",

    pub fn slice(self: StringSlice) []const u8 {
        return self.chars[0..@intCast(self.length)];
    }
};

/// Memory arena owned and managed by clay. Create with `Arena.init`.
pub const Arena = extern struct {
    next_allocation: usize = 0,
    capacity: usize = 0,
    memory: [*]u8 = undefined,

    /// Wrap a caller-owned buffer for clay to allocate from.
    pub fn init(buffer: []u8) Arena {
        return ffi.Clay_CreateArenaWithCapacityAndMemory(buffer.len, buffer.ptr);
    }
};

pub const Dimensions = extern struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const Vector2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// RGBA color. Conventionally 0-255 per channel, but interpretation is up to the
/// renderer. Note: the default is fully transparent (`a = 0`); use `.rgb`/`.rgba`
/// or the named constants for opaque colors.
pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }
    /// Convert to `[4]f32` (handy for shaders / GPU uploads).
    pub fn array(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }
    /// Parse `"#RRGGBB"` or `"#RRGGBBAA"` (the leading `#` is optional) at comptime.
    pub fn hex(comptime str: []const u8) Color {
        const s = comptime if (str.len > 0 and str[0] == '#') str[1..] else str;
        if (s.len != 6 and s.len != 8) @compileError("Color.hex expects \"#RRGGBB\" or \"#RRGGBBAA\"");
        return .{
            .r = comptime hexByte(s[0..2]),
            .g = comptime hexByte(s[2..4]),
            .b = comptime hexByte(s[4..6]),
            .a = if (s.len == 8) comptime hexByte(s[6..8]) else 255,
        };
    }

    fn hexByte(comptime h: []const u8) f32 {
        return @floatFromInt(std.fmt.parseInt(u8, h, 16) catch @compileError("Color.hex: invalid hex digits"));
    }

    pub const transparent: Color = .{};
    pub const white = rgb(255, 255, 255);
    pub const black = rgb(0, 0, 0);
    pub const red = rgb(255, 0, 0);
    pub const green = rgb(0, 255, 0);
    pub const blue = rgb(0, 0, 255);
};

pub const BoundingBox = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: BoundingBox, p: Vector2) bool {
        return p.x >= self.x and p.x <= self.x + self.width and
            p.y >= self.y and p.y <= self.y + self.height;
    }
};

/// Controls corner rounding of rectangles, borders and images.
pub const CornerRadius = extern struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_left: f32 = 0,
    bottom_right: f32 = 0,

    pub fn all(radius: f32) CornerRadius {
        return .{ .top_left = radius, .top_right = radius, .bottom_left = radius, .bottom_right = radius };
    }
};

/// A hashed element id. Build with `id`, `idi`, `localId`, `localIdi`, `idFromSrc`.
pub const ElementId = extern struct {
    id: u32 = 0,
    offset: u32 = 0,
    base_id: u32 = 0,
    string_id: String = .{},
};

/// clay's growable array layout. Returned arrays are sliced for you.
pub fn ClayArray(comptime T: type) type {
    return extern struct {
        capacity: i32 = 0,
        length: i32 = 0,
        internal_array: [*]T = undefined,

        pub fn slice(self: @This()) []T {
            return self.internal_array[0..@intCast(self.length)];
        }
    };
}

pub const ElementIdArray = ClayArray(ElementId);
pub const RenderCommandArray = ClayArray(RenderCommand);

// =============================================================================
// Enums
// =============================================================================

pub const LayoutDirection = enum(u8) { left_to_right, top_to_bottom };
pub const LayoutAlignmentX = enum(u8) { left, right, center };
pub const LayoutAlignmentY = enum(u8) { top, bottom, center };
pub const SizingType = enum(u8) { fit, grow, percent, fixed };
pub const TextWrapMode = enum(u8) { words, newlines, none };
pub const TextAlignment = enum(u8) { left, center, right };

pub const FloatingAttachPointType = enum(u8) {
    left_top,
    left_center,
    left_bottom,
    center_top,
    center_center,
    center_bottom,
    right_top,
    right_center,
    right_bottom,
};

pub const PointerCaptureMode = enum(u8) { capture, passthrough };
pub const FloatingAttachToElement = enum(u8) { none, parent, element_with_id, root };
pub const FloatingClipToElement = enum(u8) { none, attached_parent };

pub const PointerState = enum(u8) {
    pressed_this_frame,
    pressed,
    released_this_frame,
    released,
};

pub const RenderCommandType = enum(u8) {
    none,
    rectangle,
    border,
    text,
    image,
    scissor_start,
    scissor_end,
    overlay_color_start,
    overlay_color_end,
    custom,
};

pub const ErrorType = enum(u8) {
    text_measurement_function_not_provided,
    arena_capacity_exceeded,
    elements_capacity_exceeded,
    text_measurement_capacity_exceeded,
    duplicate_id,
    floating_container_parent_not_found,
    percentage_over_1,
    internal_error,
    unbalanced_open_close,
    hash_map_capacity_exceeded,
};

// =============================================================================
// Layout configuration
// =============================================================================

pub const SizingMinMax = extern struct {
    min: f32 = 0,
    max: f32 = 0,
};

const SizingSize = extern union {
    minmax: SizingMinMax,
    percent: f32,
};

/// Sizing of an element along one axis. Use the decl-literal helpers:
/// `.grow`, `.fit`, `.fixed(200)`, `.percent(0.5)`.
pub const SizingAxis = extern struct {
    size: SizingSize = .{ .minmax = .{} },
    type: SizingType = .fit,

    pub const grow: SizingAxis = .{ .type = .grow, .size = .{ .minmax = .{} } };
    pub const fit: SizingAxis = .{ .type = .fit, .size = .{ .minmax = .{} } };

    pub fn fixed(px: f32) SizingAxis {
        return .{ .type = .fixed, .size = .{ .minmax = .{ .min = px, .max = px } } };
    }
    pub fn percent(p: f32) SizingAxis {
        return .{ .type = .percent, .size = .{ .percent = p } };
    }
    pub fn growMinMax(mm: SizingMinMax) SizingAxis {
        return .{ .type = .grow, .size = .{ .minmax = mm } };
    }
    pub fn fitMinMax(mm: SizingMinMax) SizingAxis {
        return .{ .type = .fit, .size = .{ .minmax = mm } };
    }
};

pub const Sizing = extern struct {
    width: SizingAxis = .{},
    height: SizingAxis = .{},

    pub const grow: Sizing = .{ .width = .grow, .height = .grow };
    pub const fit: Sizing = .{ .width = .fit, .height = .fit };

    pub fn fixed(w: f32, h: f32) Sizing {
        return .{ .width = SizingAxis.fixed(w), .height = SizingAxis.fixed(h) };
    }
};

pub const Padding = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(v: u16) Padding {
        return .{ .left = v, .right = v, .top = v, .bottom = v };
    }
    /// `axes(vertical, horizontal)`.
    pub fn axes(top_bottom: u16, left_right: u16) Padding {
        return .{ .top = top_bottom, .bottom = top_bottom, .left = left_right, .right = left_right };
    }
    pub fn horizontal(v: u16) Padding {
        return .{ .left = v, .right = v };
    }
    pub fn vertical(v: u16) Padding {
        return .{ .top = v, .bottom = v };
    }
};

pub const ChildAlignment = extern struct {
    x: LayoutAlignmentX = .left,
    y: LayoutAlignmentY = .top,

    pub const center: ChildAlignment = .{ .x = .center, .y = .center };
};

pub const LayoutConfig = extern struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: u16 = 0,
    child_alignment: ChildAlignment = .{},
    direction: LayoutDirection = .left_to_right,
};

// =============================================================================
// Element configs
// =============================================================================

pub const TextConfig = extern struct {
    /// Passed through to the resulting TEXT render command.
    user_data: ?*anyopaque = null,
    color: Color = Color.black,
    font_id: u16 = 0,
    font_size: u16 = 20,
    letter_spacing: u16 = 0,
    line_height: u16 = 0,
    wrap_mode: TextWrapMode = .words,
    alignment: TextAlignment = .left,
};

pub const AspectRatioConfig = extern struct {
    /// final width / final height; 0 = unconstrained.
    aspect_ratio: f32 = 0,
};

pub const ImageConfig = extern struct {
    /// Opaque pointer handed back to your renderer for IMAGE commands.
    image_data: ?*anyopaque = null,
};

pub const FloatingAttachPoints = extern struct {
    element: FloatingAttachPointType = .left_top,
    parent: FloatingAttachPointType = .left_top,
};

pub const FloatingConfig = extern struct {
    offset: Vector2 = .{},
    expand: Dimensions = .{},
    parent_id: u32 = 0,
    z_index: i16 = 0,
    attach_points: FloatingAttachPoints = .{},
    pointer_capture_mode: PointerCaptureMode = .capture,
    /// Floating is inactive unless this is set to something other than `.none`.
    attach_to: FloatingAttachToElement = .none,
    clip_to: FloatingClipToElement = .none,
};

pub const CustomConfig = extern struct {
    /// Opaque pointer handed back to your renderer for CUSTOM commands.
    custom_data: ?*anyopaque = null,
};

/// Clips overflowing content and enables scrolling on the chosen axes.
pub const ClipConfig = extern struct {
    horizontal: bool = false,
    vertical: bool = false,
    /// Offsets all children; feed `getScrollOffset()` here for scroll containers.
    child_offset: Vector2 = .{},
};

pub const BorderWidth = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,
    between_children: u16 = 0,

    pub fn all(v: u16) BorderWidth {
        return .{ .left = v, .right = v, .top = v, .bottom = v, .between_children = v };
    }
    /// Outer edges only (no border between children).
    pub fn outside(v: u16) BorderWidth {
        return .{ .left = v, .right = v, .top = v, .bottom = v };
    }
};

pub const BorderConfig = extern struct {
    color: Color = Color.black,
    width: BorderWidth = .{},
};

// =============================================================================
// Transitions / animation (main-only)
// =============================================================================

pub const TransitionState = enum(c_int) { idle, entering, transitioning, exiting };

/// Which properties a transition animates. Combine with struct literals
/// (`.{ .background_color = true, .x = true }`) or the named groups below.
pub const TransitionProperty = packed struct(i32) {
    x: bool = false,
    y: bool = false,
    width: bool = false,
    height: bool = false,
    background_color: bool = false,
    overlay_color: bool = false,
    corner_radius: bool = false,
    border_color: bool = false,
    border_width: bool = false,
    _padding: u23 = 0,

    pub const position: TransitionProperty = .{ .x = true, .y = true };
    pub const dimensions: TransitionProperty = .{ .width = true, .height = true };
    pub const bounding_box: TransitionProperty = .{ .x = true, .y = true, .width = true, .height = true };
    pub const border: TransitionProperty = .{ .border_color = true, .border_width = true };

    /// Bitwise OR of two property sets.
    pub fn merge(a: TransitionProperty, b: TransitionProperty) TransitionProperty {
        return @bitCast(@as(i32, @bitCast(a)) | @as(i32, @bitCast(b)));
    }
};

pub const TransitionData = extern struct {
    bounding_box: BoundingBox = .{},
    background_color: Color = .{},
    overlay_color: Color = .{},
    border_color: Color = .{},
    border_width: BorderWidth = .{},
};

pub const TransitionCallbackArguments = extern struct {
    transition_state: TransitionState,
    initial: TransitionData,
    current: *TransitionData,
    target: TransitionData,
    elapsed_time: f32,
    duration: f32,
    properties: TransitionProperty,
};

pub const TransitionEnterTriggerType = enum(u8) {
    skip_on_first_parent_frame,
    trigger_on_first_parent_frame,
};
pub const TransitionExitTriggerType = enum(u8) {
    skip_when_parent_exits,
    trigger_when_parent_exits,
};
pub const TransitionInteractionHandlingType = enum(u8) {
    disable_interactions_while_transitioning_position,
    allow_interactions_while_transitioning_position,
};
pub const ExitTransitionSiblingOrdering = enum(u8) {
    underneath_siblings,
    natural_order,
    above_siblings,
};

/// Per-frame transition tick. Return `true` while still animating, `false` when done.
pub const TransitionHandler = *const fn (TransitionCallbackArguments) callconv(.c) bool;
/// Produces the start/end snapshot for enter/exit animations.
pub const TransitionStateFn = *const fn (TransitionData, TransitionProperty) callconv(.c) TransitionData;

pub const TransitionEnter = extern struct {
    set_initial_state: ?TransitionStateFn = null,
    trigger: TransitionEnterTriggerType = .skip_on_first_parent_frame,
};

pub const TransitionExit = extern struct {
    set_final_state: ?TransitionStateFn = null,
    trigger: TransitionExitTriggerType = .skip_when_parent_exits,
    sibling_ordering: ExitTransitionSiblingOrdering = .underneath_siblings,
};

/// Attach to an element's `.transition` to animate it. Inactive while
/// `handler == null` / `duration == 0`. Use `clay.easeOut` for a ready handler.
pub const TransitionConfig = extern struct {
    handler: ?TransitionHandler = null,
    duration: f32 = 0,
    properties: TransitionProperty = .{},
    interaction_handling: TransitionInteractionHandlingType = .disable_interactions_while_transitioning_position,
    enter: TransitionEnter = .{},
    exit: TransitionExit = .{},
};

/// Built-in "ease out" transition handler.
pub const easeOut: TransitionHandler = &ffi.Clay_EaseOut;

// =============================================================================
// Element declaration + the layout DSL
// =============================================================================

/// Everything that describes a single element. The `id` is supplied separately
/// to `openId`; for `open` it is auto-generated.
pub const ElementDeclaration = extern struct {
    layout: LayoutConfig = .{},
    /// Default is transparent. If set with no other config, generates a RECTANGLE.
    background_color: Color = .{},
    /// `mix(elementColor, overlayColor.rgb, overlayColor.a)` over this subtree.
    overlay_color: Color = .{},
    corner_radius: CornerRadius = .{},
    aspect_ratio: AspectRatioConfig = .{},
    image: ImageConfig = .{},
    floating: FloatingConfig = .{},
    custom: CustomConfig = .{},
    clip: ClipConfig = .{},
    border: BorderConfig = .{},
    transition: TransitionConfig = .{},
    user_data: ?*anyopaque = null,
};

/// Scope guard returned by `open`/`openId`. Pair with `defer element.end()`.
pub const Element = struct {
    /// The hashed id of this element (queryable after layout).
    id: u32,

    /// Close this element. Always `defer element.end();` right after opening.
    pub fn end(self: Element) void {
        _ = self;
        ffi.Clay__CloseElement();
    }

    /// True if the pointer is over this (currently open) element this frame.
    pub fn hovered(self: Element) bool {
        _ = self;
        return ffi.Clay_Hovered();
    }

    /// Final bounding box from the previous frame, if the element existed.
    pub fn boundingBox(self: Element) ?BoundingBox {
        const data = ffi.Clay_GetElementData(.{ .id = self.id });
        return if (data.found) data.bounding_box else null;
    }

    /// Register a hover callback for this element. `T` must be pointer-sized or `void`.
    pub fn onHover(
        self: Element,
        comptime T: type,
        user_data: T,
        comptime callback: fn (ElementId, PointerData, T) void,
    ) void {
        _ = self;
        bindHover(T, user_data, callback);
    }
};

/// Open an element with an auto-generated id. `defer e.end();` then declare children.
pub fn open(declaration: ElementDeclaration) Element {
    ffi.Clay__OpenElement();
    ffi.Clay__ConfigureOpenElement(declaration);
    return .{ .id = ffi.Clay_GetOpenElementId() };
}

/// Open an element with an explicit id (needed for hover/scroll/data queries).
pub fn openId(element_id: ElementId, declaration: ElementDeclaration) Element {
    ffi.Clay__OpenElementWithId(element_id);
    ffi.Clay__ConfigureOpenElement(declaration);
    return .{ .id = ffi.Clay_GetOpenElementId() };
}

/// Imperative close, for building trees that don't map to lexical scopes.
/// Prefer `defer element.end();`.
pub fn close() void {
    ffi.Clay__CloseElement();
}

/// Declare a text element (leaf). The bytes are not copied; keep them alive for
/// the frame. Use `textComptime` for string literals to enable measurement caching.
pub fn text(string: []const u8, config: TextConfig) void {
    ffi.Clay__OpenTextElement(String.fromSlice(string), config);
}

/// Like `text`, but marks the string as statically allocated (cacheable).
pub fn textComptime(comptime string: []const u8, config: TextConfig) void {
    ffi.Clay__OpenTextElement(String.fromComptime(string), config);
}

// =============================================================================
// Element ids
// =============================================================================

/// Global id from a string.
pub fn id(label: []const u8) ElementId {
    return ffi.Clay__HashString(String.fromSlice(label), 0);
}
/// Global id with an index suffix (for loops), without building a new string.
pub fn idi(label: []const u8, index: u32) ElementId {
    return ffi.Clay__HashStringWithOffset(String.fromSlice(label), index, 0);
}
/// Id scoped to the currently open element.
pub fn localId(label: []const u8) ElementId {
    return ffi.Clay__HashString(String.fromSlice(label), ffi.Clay_GetOpenElementId());
}
/// Indexed id scoped to the currently open element.
pub fn localIdi(label: []const u8, index: u32) ElementId {
    return ffi.Clay__HashStringWithOffset(String.fromSlice(label), index, ffi.Clay_GetOpenElementId());
}
/// Auto-derive a stable id from a source location.
pub fn idFromSrc(comptime src: std.builtin.SourceLocation) ElementId {
    return ffi.Clay__HashString(String.fromComptime(src.file ++ std.fmt.comptimePrint(":{d}:{d}", .{ src.line, src.column })), 0);
}

// =============================================================================
// Lifecycle
// =============================================================================

/// Minimum arena size in bytes for the current configuration.
pub const minMemorySize = ffi.Clay_MinMemorySize;

/// Initialize clay against a prepared arena. Returns the active context.
pub const initialize = ffi.Clay_Initialize;

/// Like `initialize`, but allocates the arena via `gpa` (must be arena-like;
/// the allocation is never individually freed).
pub fn initializeAlloc(gpa: std.mem.Allocator, layout_dimensions: Dimensions, error_handler: ErrorHandler) !*Context {
    const buffer = try gpa.alloc(u8, minMemorySize());
    return initialize(Arena.init(buffer), layout_dimensions, error_handler);
}

pub const getCurrentContext = ffi.Clay_GetCurrentContext;
pub const setCurrentContext = ffi.Clay_SetCurrentContext;

pub const getMaxElementCount = ffi.Clay_GetMaxElementCount;
pub const setMaxElementCount = ffi.Clay_SetMaxElementCount;
pub const getMaxMeasureTextCacheWordCount = ffi.Clay_GetMaxMeasureTextCacheWordCount;
pub const setMaxMeasureTextCacheWordCount = ffi.Clay_SetMaxMeasureTextCacheWordCount;
pub const resetMeasureTextCache = ffi.Clay_ResetMeasureTextCache;

// =============================================================================
// Per-frame
// =============================================================================

pub const setLayoutDimensions = ffi.Clay_SetLayoutDimensions;
pub const getLayoutDimensions = ffi.Clay_GetLayoutDimensions;
pub const setPointerState = ffi.Clay_SetPointerState;
pub const getPointerState = ffi.Clay_GetPointerState;
pub const updateScrollContainers = ffi.Clay_UpdateScrollContainers;
pub const getScrollOffset = ffi.Clay_GetScrollOffset;

/// Begin a new layout frame. Declare elements, then call `endLayout`.
pub const beginLayout = ffi.Clay_BeginLayout;

/// Finish the frame and return the render commands. `delta_time` (seconds) drives
/// transitions. The returned slice is valid until the next `beginLayout`.
pub fn endLayout(delta_time: f32) []RenderCommand {
    return ffi.Clay_EndLayout(delta_time).slice();
}

// =============================================================================
// Queries / interaction
// =============================================================================

pub const getOpenElementId = ffi.Clay_GetOpenElementId;
pub const getElementData = ffi.Clay_GetElementData;
pub const getScrollContainerData = ffi.Clay_GetScrollContainerData;

/// Scroll offset for a clip element *by id* (works before the element is opened).
/// Feed this into `ClipConfig.child_offset` to build a scroll container:
/// ```
/// const sid = cl.id("Panel");
/// const p = cl.openId(sid, .{ .clip = .{ .vertical = true, .child_offset = cl.scrollOffset(sid) } });
/// defer p.end();
/// ```
pub fn scrollOffset(element_id: ElementId) Vector2 {
    const data = ffi.Clay_GetScrollContainerData(element_id);
    return if (data.found) data.scroll_position.* else .{};
}

/// True if the pointer is over the currently open element (use inside a scope).
pub const hovered = ffi.Clay_Hovered;
/// True if the pointer is over the element with `element_id` (last frame).
pub const pointerOver = ffi.Clay_PointerOver;

pub fn getElementId(label: []const u8) ElementId {
    return ffi.Clay_GetElementId(String.fromSlice(label));
}
pub fn getElementIdWithIndex(label: []const u8, index: u32) ElementId {
    return ffi.Clay_GetElementIdWithIndex(String.fromSlice(label), index);
}

/// Ids the pointer is currently over, innermost first. Valid until next layout.
pub fn getPointerOverIds() []ElementId {
    return ffi.Clay_GetPointerOverIds().slice();
}

// =============================================================================
// Debug / culling
// =============================================================================

pub const setDebugModeEnabled = ffi.Clay_SetDebugModeEnabled;
pub const isDebugModeEnabled = ffi.Clay_IsDebugModeEnabled;
pub const setCullingEnabled = ffi.Clay_SetCullingEnabled;

extern var Clay__debugViewHighlightColor: Color;
extern var Clay__debugViewWidth: u32;

pub fn setDebugHighlightColor(color: Color) void {
    Clay__debugViewHighlightColor = color;
}
pub fn setDebugViewWidth(width: u32) void {
    Clay__debugViewWidth = width;
}

// =============================================================================
// Callbacks (typed user data: any pointer-sized value, or `void`)
// =============================================================================

/// Provide text measurement. Required before declaring any text elements.
pub fn setMeasureTextFunction(
    comptime T: type,
    user_data: T,
    comptime measure: fn ([]const u8, *TextConfig, T) Dimensions,
) void {
    assertUserDataType(T);
    const W = struct {
        fn cb(s: StringSlice, cfg: *TextConfig, ud: ?*anyopaque) callconv(.c) Dimensions {
            return measure(s.slice(), cfg, fromOpaque(T, ud));
        }
    };
    ffi.Clay_SetMeasureTextFunction(W.cb, toOpaque(user_data));
}

/// Bind a hover callback to the currently open element.
pub fn onHover(
    comptime T: type,
    user_data: T,
    comptime callback: fn (ElementId, PointerData, T) void,
) void {
    bindHover(T, user_data, callback);
}

fn bindHover(
    comptime T: type,
    user_data: T,
    comptime callback: fn (ElementId, PointerData, T) void,
) void {
    assertUserDataType(T);
    const W = struct {
        fn cb(eid: ElementId, p: PointerData, ud: ?*anyopaque) callconv(.c) void {
            callback(eid, p, fromOpaque(T, ud));
        }
    };
    ffi.Clay_OnHover(W.cb, toOpaque(user_data));
}

/// Hand scroll handling to your own system: clay stops applying scroll deltas in
/// `updateScrollContainers` and instead queries you via `setQueryScrollOffsetFunction`.
pub const setExternalScrollHandling = ffi.Clay_SetExternalScrollHandlingEnabled;

/// Experimental: integrate clay with an externally managed scrolling system.
pub fn setQueryScrollOffsetFunction(
    comptime T: type,
    user_data: T,
    comptime query: fn (u32, T) Vector2,
) void {
    assertUserDataType(T);
    const W = struct {
        fn cb(element_id: u32, ud: ?*anyopaque) callconv(.c) Vector2 {
            return query(element_id, fromOpaque(T, ud));
        }
    };
    ffi.Clay_SetQueryScrollOffsetFunction(W.cb, toOpaque(user_data));
}

fn assertUserDataType(comptime T: type) void {
    if (T != void and @sizeOf(T) != @sizeOf(usize))
        @compileError("user_data type `" ++ @typeName(T) ++ "` must be pointer-sized or `void`");
}

fn toOpaque(user_data: anytype) ?*anyopaque {
    const T = @TypeOf(user_data);
    if (T == void) return null;
    if (@typeInfo(T) == .pointer) return @ptrCast(@constCast(user_data));
    return @ptrFromInt(@as(usize, @bitCast(user_data)));
}

fn fromOpaque(comptime T: type, user_data: ?*anyopaque) T {
    if (T == void) return {};
    if (@typeInfo(T) == .pointer) return @ptrCast(@alignCast(user_data));
    return @bitCast(@as(usize, @intFromPtr(user_data)));
}

// =============================================================================
// Errors
// =============================================================================

pub const ErrorData = extern struct {
    error_type: ErrorType,
    error_text: String,
    user_data: ?*anyopaque,
};

pub const ErrorHandler = extern struct {
    error_handler_function: ?*const fn (ErrorData) callconv(.c) void = null,
    user_data: ?*anyopaque = null,
};

/// Logs clay errors via `std.log.scoped(.clay)`.
pub fn defaultErrorHandlerFn(data: ErrorData) callconv(.c) void {
    std.log.scoped(.clay).err("{s}: {s}", .{ @tagName(data.error_type), data.error_text.slice() });
}

/// A ready-made error handler that logs. Pass to `initialize`.
pub const default_error_handler: ErrorHandler = .{ .error_handler_function = &defaultErrorHandlerFn };

// =============================================================================
// Render commands (consumed by your renderer)
// =============================================================================

pub const RectangleData = extern struct {
    background_color: Color,
    corner_radius: CornerRadius,
};

pub const TextData = extern struct {
    string_contents: StringSlice,
    text_color: Color,
    font_id: u16,
    font_size: u16,
    letter_spacing: u16,
    line_height: u16,

    /// The text bytes to draw.
    pub fn slice(self: TextData) []const u8 {
        return self.string_contents.slice();
    }
};

pub const ImageData = extern struct {
    /// Tint; `{0,0,0,0}` conventionally means "untinted".
    background_color: Color,
    corner_radius: CornerRadius,
    image_data: ?*anyopaque,

    /// Recover the typed pointer you passed via `ImageConfig.image_data`.
    pub fn imageAs(self: ImageData, comptime T: type) ?*T {
        return @ptrCast(@alignCast(self.image_data));
    }
};

pub const CustomData = extern struct {
    background_color: Color,
    corner_radius: CornerRadius,
    custom_data: ?*anyopaque,

    /// Recover the typed pointer you passed via `CustomConfig.custom_data`.
    pub fn dataAs(self: CustomData, comptime T: type) ?*T {
        return @ptrCast(@alignCast(self.custom_data));
    }
};

pub const ClipData = extern struct {
    horizontal: bool,
    vertical: bool,
};

pub const OverlayData = extern struct {
    color: Color,
};

pub const BorderData = extern struct {
    color: Color,
    corner_radius: CornerRadius,
    width: BorderWidth,
};

/// Raw clay render-data union (ABI). Prefer `RenderCommand.data()`.
pub const RenderDataRaw = extern union {
    rectangle: RectangleData,
    text: TextData,
    image: ImageData,
    custom: CustomData,
    border: BorderData,
    clip: ClipData,
    overlay_color: OverlayData,
};

/// Tagged view of a render command's payload — `switch` over this in your renderer.
pub const RenderData = union(enum) {
    none,
    rectangle: RectangleData,
    border: BorderData,
    text: TextData,
    image: ImageData,
    scissor_start: ClipData,
    scissor_end: ClipData,
    overlay_start: OverlayData,
    overlay_end: OverlayData,
    custom: CustomData,
};

pub const RenderCommand = extern struct {
    bounding_box: BoundingBox,
    render_data: RenderDataRaw,
    user_data: ?*anyopaque,
    id: u32,
    /// Already sorted ascending; provided for batching renderers.
    z_index: i16,
    command_type: RenderCommandType,

    /// Pair `command_type` with its payload as a Zig tagged union.
    pub fn data(self: *const RenderCommand) RenderData {
        return switch (self.command_type) {
            .none => .none,
            .rectangle => .{ .rectangle = self.render_data.rectangle },
            .border => .{ .border = self.render_data.border },
            .text => .{ .text = self.render_data.text },
            .image => .{ .image = self.render_data.image },
            .scissor_start => .{ .scissor_start = self.render_data.clip },
            .scissor_end => .{ .scissor_end = self.render_data.clip },
            .overlay_color_start => .{ .overlay_start = self.render_data.overlay_color },
            .overlay_color_end => .{ .overlay_end = self.render_data.overlay_color },
            .custom => .{ .custom = self.render_data.custom },
        };
    }

    /// Recover a typed pointer from the command-level `user_data`.
    pub fn userDataAs(self: *const RenderCommand, comptime T: type) ?*T {
        return @ptrCast(@alignCast(self.user_data));
    }
};

// =============================================================================
// Misc query result types
// =============================================================================

pub const PointerData = extern struct {
    position: Vector2,
    state: PointerState,
};

pub const ScrollContainerData = extern struct {
    /// Pointer to the live internal scroll position; mutate to scroll programmatically.
    scroll_position: *Vector2,
    scroll_container_dimensions: Dimensions,
    content_dimensions: Dimensions,
    config: ClipConfig,
    found: bool,
};

pub const ElementData = extern struct {
    bounding_box: BoundingBox,
    found: bool,
};

// =============================================================================
// Raw C entry points (re-implemented macros + direct exports)
// =============================================================================

/// Direct, unwrapped clay C functions — private; the public API above wraps all of them.
const ffi = struct {
    pub extern fn Clay_MinMemorySize() u32;
    pub extern fn Clay_CreateArenaWithCapacityAndMemory(capacity: usize, memory: ?*anyopaque) Arena;
    pub extern fn Clay_SetPointerState(position: Vector2, pointer_down: bool) void;
    pub extern fn Clay_GetPointerState() PointerData;
    pub extern fn Clay_Initialize(arena: Arena, layout_dimensions: Dimensions, error_handler: ErrorHandler) *Context;
    pub extern fn Clay_GetCurrentContext() ?*Context;
    pub extern fn Clay_SetCurrentContext(context: *Context) void;
    pub extern fn Clay_UpdateScrollContainers(enable_drag_scrolling: bool, scroll_delta: Vector2, delta_time: f32) void;
    pub extern fn Clay_GetScrollOffset() Vector2;
    pub extern fn Clay_SetLayoutDimensions(dimensions: Dimensions) void;
    pub extern fn Clay_GetLayoutDimensions() Dimensions;
    pub extern fn Clay_BeginLayout() void;
    pub extern fn Clay_EndLayout(delta_time: f32) RenderCommandArray;
    pub extern fn Clay_GetOpenElementId() u32;
    pub extern fn Clay_GetElementId(id_string: String) ElementId;
    pub extern fn Clay_GetElementIdWithIndex(id_string: String, index: u32) ElementId;
    pub extern fn Clay_GetElementData(id: ElementId) ElementData;
    pub extern fn Clay_Hovered() bool;
    pub extern fn Clay_OnHover(on_hover: *const fn (ElementId, PointerData, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void;
    pub extern fn Clay_PointerOver(id: ElementId) bool;
    pub extern fn Clay_GetPointerOverIds() ElementIdArray;
    pub extern fn Clay_GetScrollContainerData(id: ElementId) ScrollContainerData;
    pub extern fn Clay_SetMeasureTextFunction(measure: *const fn (StringSlice, *TextConfig, ?*anyopaque) callconv(.c) Dimensions, user_data: ?*anyopaque) void;
    pub extern fn Clay_SetQueryScrollOffsetFunction(query: *const fn (u32, ?*anyopaque) callconv(.c) Vector2, user_data: ?*anyopaque) void;
    pub extern fn Clay_SetExternalScrollHandlingEnabled(enabled: bool) void;
    pub extern fn Clay_RenderCommandArray_Get(array: *RenderCommandArray, index: i32) *RenderCommand;
    pub extern fn Clay_SetDebugModeEnabled(enabled: bool) void;
    pub extern fn Clay_IsDebugModeEnabled() bool;
    pub extern fn Clay_SetCullingEnabled(enabled: bool) void;
    pub extern fn Clay_GetMaxElementCount() i32;
    pub extern fn Clay_SetMaxElementCount(max_element_count: i32) void;
    pub extern fn Clay_GetMaxMeasureTextCacheWordCount() i32;
    pub extern fn Clay_SetMaxMeasureTextCacheWordCount(max_word_count: i32) void;
    pub extern fn Clay_ResetMeasureTextCache() void;
    pub extern fn Clay_EaseOut(args: TransitionCallbackArguments) bool;

    // Internal entry points the C macros expand to:
    pub extern fn Clay__OpenElement() void;
    pub extern fn Clay__OpenElementWithId(id: ElementId) void;
    pub extern fn Clay__ConfigureOpenElement(config: ElementDeclaration) void;
    pub extern fn Clay__ConfigureOpenElementPtr(config: *const ElementDeclaration) void;
    pub extern fn Clay__CloseElement() void;
    pub extern fn Clay__HashString(key: String, seed: u32) ElementId;
    pub extern fn Clay__HashStringWithOffset(key: String, offset: u32, seed: u32) ElementId;
    pub extern fn Clay__OpenTextElement(text: String, config: TextConfig) void;
};

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
    _ = @import("abi_verify.zig");
}

fn measureStub(s: []const u8, cfg: *TextConfig, _: void) Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.5,
        .height = @floatFromInt(cfg.font_size),
    };
}

test "end to end layout produces render commands" {
    const buffer = try std.testing.allocator.alloc(u8, minMemorySize());
    defer std.testing.allocator.free(buffer);

    _ = initialize(Arena.init(buffer), .{ .width = 800, .height = 600 }, default_error_handler);
    setMeasureTextFunction(void, {}, measureStub);

    beginLayout();
    {
        const root = openId(id("Root"), .{
            .layout = .{
                .sizing = .grow,
                .padding = .all(16),
                .direction = .top_to_bottom,
                .child_gap = 8,
            },
            .background_color = .rgb(20, 20, 30),
        });
        defer root.end();

        textComptime("Hello, clay", .{ .font_size = 24, .color = .white });

        for (0..3) |i| {
            const row_id = idi("Row", @intCast(i));
            const card = openId(row_id, .{
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .axes(4, 12) },
                .background_color = if (pointerOver(row_id)) Color.rgb(60, 60, 80) else Color.rgb(40, 40, 55),
                .corner_radius = .all(6),
            });
            defer card.end();
            text("row", .{});
        }
    }
    const commands = endLayout(0.016);

    try std.testing.expect(commands.len > 0);

    var saw_rectangle = false;
    var saw_text = false;
    for (commands) |*cmd| switch (cmd.data()) {
        .rectangle => saw_rectangle = true,
        .text => |t| {
            saw_text = true;
            try std.testing.expect(t.slice().len > 0);
        },
        else => {},
    };
    try std.testing.expect(saw_rectangle);
    try std.testing.expect(saw_text);
}

test "color helpers" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 255 }, Color.white);
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 128, .a = 255 }, Color.hex("#FF0080"));
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, Color.transparent);
}

test "transition property flags map to clay bit values" {
    try std.testing.expectEqual(@as(i32, 1), @as(i32, @bitCast(TransitionProperty{ .x = true })));
    try std.testing.expectEqual(@as(i32, 16), @as(i32, @bitCast(TransitionProperty{ .background_color = true })));
    try std.testing.expectEqual(@as(i32, 256), @as(i32, @bitCast(TransitionProperty{ .border_width = true })));
    try std.testing.expectEqual(@as(i32, 3), @as(i32, @bitCast(TransitionProperty.position)));
}
