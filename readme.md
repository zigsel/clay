# clay-zig

Idiomatic Zig bindings for [Clay](https://github.com/nicbarker/clay), tracking
`main` (the unreleased line **with transitions/animations and overlays**).

- Native Zig types with defaults + decl-literal helpers (`.grow`, `.all(16)`, `.rgb(…)`).
- `defer`-guarded layout DSL with ordinary nested block scopes.
- Render commands consumed as an exhaustive Zig **tagged union** (`cmd.data()`).
- Full `main` surface: layout, text, images, floating, clip/scroll, borders,
  **transitions**, **overlay color**, multi-context, debug tools.
- Every struct is **ABI-checked against the real `clay.h` at build time** — if you
  bump clay and a layout changes, `zig build test` fails loudly instead of
  corrupting memory silently.

Pinned clay commit: `e6cc369` · Zig `0.16`.

## Install

```sh
zig fetch --save=clay "git+https://github.com/zigsel/clay"
```

```zig
// build.zig
const clay = b.dependency("clay", .{}); // or .{ .@"disable-simd" = true }
exe.root_module.addImport("clay", clay.module("clay"));
```

## Per-frame usage

```zig
const cl = @import("clay");

// --- once at startup ---
const memory = try gpa.alloc(u8, cl.minMemorySize());
_ = cl.initialize(cl.Arena.init(memory), .{ .width = 1280, .height = 720 }, cl.default_error_handler);
cl.setMeasureTextFunction(*Fonts, &fonts, measureText);

// --- each frame ---
cl.setLayoutDimensions(.{ .width = w, .height = h });
cl.setPointerState(.{ .x = mouse_x, .y = mouse_y }, mouse_down);
cl.updateScrollContainers(true, .{ .x = scroll_x, .y = scroll_y }, dt);

cl.beginLayout();
ui();                                  // declare your tree (below)
const commands = cl.endLayout(dt);     // dt drives transitions

renderer.render(commands, &backend);   // see examples/renderer_skeleton.zig
```

## The layout DSL

`open` (auto id) / `openId` (explicit id) return a guard; pair with `defer`.
Children are just declarations inside the block scope.

```zig
fn ui() void {
    const root = cl.open(.{
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow, .padding = .all(16), .child_gap = 8 },
        .background_color = .rgb(24, 24, 32),
    });
    defer root.end();

    cl.text("Files", .{ .font_size = 24, .color = .white });

    for (items, 0..) |item, i| {
        const row_id = cl.idi("Row", @intCast(i));
        const hot = cl.pointerOver(row_id);          // dynamic styling — no open element needed
        const row = cl.openId(row_id, .{
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .axes(8, 12) },
            .background_color = if (hot) .rgb(60, 60, 80) else .rgb(40, 40, 55),
            .corner_radius = .all(6),
        });
        defer row.end();
        cl.text(item.name, .{ .color = .white });
    }
}
```

Notes:
- **Dynamic hover styling:** use `cl.pointerOver(id)` (last-frame query) rather than
  `cl.hovered()`, because the declaration struct is evaluated before the element opens.
  After `open`, the guard's `row.hovered()` / `row.onHover(...)` / `row.boundingBox()` work.
- **Imperative trees:** if your tree isn't lexical, `cl.close()` is the manual escape hatch.

## Scroll containers

```zig
const sid = cl.id("Panel");
const panel = cl.openId(sid, .{
    .clip = .{ .vertical = true, .child_offset = cl.scrollOffset(sid) },
    .layout = .{ .sizing = .grow },
});
defer panel.end();
// … long content …
```

## Transitions (main-only)

Attach a `transition` to animate properties between frames; `cl.easeOut` is built in.

```zig
const card = cl.openId(cl.id("Card"), .{
    .background_color = if (open) .rgb(80, 80, 200) else .rgb(40, 40, 55),
    .transition = .{
        .handler = cl.easeOut,
        .duration = 0.2,
        .properties = .background_color,           // or .bounding_box, .position, .{ .width = true, … }
        .enter = .{ .trigger = .trigger_on_first_parent_frame },
        .exit = .{ .trigger = .trigger_when_parent_exits },
    },
});
defer card.end();
```

Exit transitions keep an element alive while it animates out, even after you stop
declaring it — pass a real `dt` to `endLayout` to drive them.

## Rendering

Render commands are pre-sorted by z-order; `switch` over `cmd.data()`:

```zig
for (commands) |*cmd| switch (cmd.data()) {
    .rectangle    => |r| backend.fillRect(cmd.bounding_box, r.background_color, r.corner_radius),
    .text         => |t| backend.drawText(cmd.bounding_box, t.slice(), t.text_color, t.font_id, t.font_size),
    .image        => |im| backend.drawImage(cmd.bounding_box, im.imageAs(Texture), im.background_color),
    .border       => |b| backend.drawBorder(cmd.bounding_box, b.color, b.width, b.corner_radius),
    .scissor_start=> |c| backend.pushClip(cmd.bounding_box, c.horizontal, c.vertical),
    .scissor_end  => backend.popClip(),
    .overlay_start=> |o| backend.pushOverlay(o.color),
    .overlay_end  => backend.popOverlay(),
    .custom       => |c| backend.drawCustom(cmd.bounding_box, c.dataAs(Widget)),
    .none         => {},
};
```

`imageAs(T)` / `dataAs(T)` recover the typed pointers you passed via
`ImageConfig.image_data` / `CustomConfig.custom_data`. See
`examples/renderer_skeleton.zig` for a complete, copy-pasteable starting point.

## Build / test

```sh
zig build test                 # unit tests + ABI conformance + example
zig build -Ddisable-simd=true  # build clay without SIMD hashing
```

## Notes

- `Color` defaults to fully **transparent** (`a = 0`); use `.rgb`/`.rgba`/`.hex`/named
  constants (`.white`, `.black`, …) for opaque colors. This matches clay's
  "`{0,0,0,0}` = no rectangle" convention for `background_color`.
- The binding is the complete public surface; the raw C entry points are kept
  private so there's a single, type-safe way to call clay.
