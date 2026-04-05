// 04-DolDoc.HC — Rich REPL output: DolDoc hypertext in the terminal
// TempleOS renders DolDoc markup inline in the shell. Text, colors,
// links, images, trees — all in the same output stream.
// This is what nanoclj-zig's REPL should do via Ghostty/sixel/OSC.

// === 1. Colored output ===
// In HolyC, colors are part of the output stream.
// There are 16 colors (CGA palette), set with $FG$ and $BG$ tags.

U0 ColorDemo() {
  "$RED$Red text$FG$ ";
  "$GREEN$Green text$FG$ ";
  "$BLUE$Blue text$FG$ ";
  "$YELLOW$Yellow text$FG$\n";

  // Background colors
  "$BG,RED$$WHITE$White on red$BG$$FG$\n";
}

ColorDemo;

// === 2. Inline formatting ===
// DolDoc supports bold, underline, blink, and inversion.

U0 FormatDemo() {
  "$IV$Inverted$IV$ ";     // inverse video
  "$UL$Underlined$UL$ ";   // underline
  "$BK$Blinking$BK$\n";    // blink
}

FormatDemo;

// === 3. Clickable links ===
// In DolDoc, you can embed executable code in the output.
// Clicking a link runs HolyC code. This is the killer feature.

U0 LinkDemo() {
  // A "button" that runs code when clicked
  "$MA,\"Click me!\",LM=\"Square2(7);\n\"$\n";

  // A link to a file
  "$LK,\"Open Kernel\",A=\"/Adam/Kernel/Kernel.HC\"$\n";

  // A link that defines a new function
  "$MA,\"Define Cube\",LM=\"I64 Cube(I64 x){return x*x*x;}\n\"$\n";
}

LinkDemo;

// === 4. Inline trees (what Clojure data should look like) ===
U0 TreeDemo() {
  // DolDoc trees are collapsible
  "$TR,\"Data\"$\n";
  "$ID,2$:answer 42\n";
  "$ID,2$:pi 3.14\n";
  "$TR,\"Nested\"$\n";
  "$ID,4$:a 1\n";
  "$ID,4$:b 2\n";
  "$ID,0$\n";
}

TreeDemo;

// === 5. Color swatches for BCI values ===
// This is what (pr-hsl val) should produce in nanoclj-zig.
// In HolyC, we approximate with the 16-color palette.

U0 ColorSwatch(I64 fg_color, U8 *label, I64 value) {
  "$FG,%d$", fg_color;
  "\xDB\xDB\xDB";  // solid block characters
  "$FG$ %s = %d\n", label, value;
}

U0 BciDemo() {
  "Brain state color swatches:\n";
  ColorSwatch(BLUE, "Delta (rest)", 240);
  ColorSwatch(CYAN, "Theta (flow)", 180);
  ColorSwatch(GREEN, "Alpha (focus)", 120);
  ColorSwatch(YELLOW, "Beta (alert)", 60);
  ColorSwatch(RED, "Gamma (active)", 0);
}

BciDemo;

// === 6. A mini REPL with rich output ===
// Every result is printed with its type color-coded.

U0 TypeColorPrint(U8 *type_name, I64 color, U8 *value_str) {
  "$FG,%d$%s$FG$ %s\n", color, type_name, value_str;
}

U0 RichRepl() {
  TypeColorPrint("I64", LTBLUE, "42");
  TypeColorPrint("F64", GREEN, "3.14159");
  TypeColorPrint("U8*", YELLOW, "\"hello\"");
  TypeColorPrint("Fn", LTRED, "<Square2@0x1234>");
  TypeColorPrint("Nil", DKGRAY, "nil");
}

"Rich REPL output:\n";
RichRepl;

// === THE DOLDOC PROTOCOL FOR NANOCLJ-ZIG ===
//
// nanoclj-zig can't use DolDoc directly (not TempleOS).
// But the CONCEPT maps to terminal escape sequences:
//
// DolDoc tag          → Terminal equivalent
// ─────────────────────────────────────────
// $RED$...$FG$        → \e[31m...\e[0m  (ANSI color)
// $MA,"label",LM=..   → OSC 8;;url\eST  (hyperlink, iTerm2/Ghostty)
// $TR,"tree"$          → Tree-sitter fold markers / ANSI indent
// \xDB\xDB\xDB        → \e[48;2;R;G;Bm   \e[0m  (24-bit bg color swatch)
// $IV$...$IV$          → \e[7m...\e[27m  (inverse)
//
// For Ghostty specifically:
//   - Sixel graphics for actual color patches (not just block chars)
//   - OSC 1337 for inline images (iTerm2 protocol, Ghostty supports)
//   - Kitty graphics protocol for pixel-perfect swatches
//
// Implementation in nanoclj-zig's repl.zig:
//
//   fn printRich(val: Value, writer: anytype) void {
//     switch (val.tag()) {
//       .integer => writer.print("\x1b[94m{d}\x1b[0m", .{val.asInt()}),
//       .float   => writer.print("\x1b[32m{d}\x1b[0m", .{val.asFloat()}),
//       .string  => writer.print("\x1b[33m\"{s}\"\x1b[0m", .{val.asStr()}),
//       .nil     => writer.print("\x1b[90mnil\x1b[0m", .{}),
//       .object  => |obj| switch (obj.kind) {
//         .function => writer.print("\x1b[91m#fn\x1b[0m", .{}),
//         .map      => printMap(obj, writer),  // recursive, indented
//         .vector   => printVec(obj, writer),
//         _ => {},
//       },
//       _ => {},
//     }
//   }
//
//   fn printHslSwatch(h: f32, s: f32, l: f32, writer: anytype) void {
//     // Convert HSL to RGB for 24-bit terminal color
//     const rgb = hslToRgb(h, s, l);
//     writer.print("\x1b[48;2;{d};{d};{d}m   \x1b[0m", .{rgb.r, rgb.g, rgb.b});
//   }

// === LESSON FOR NANOCLJ-ZIG ===
// Every Value.print() should emit ANSI color codes.
// Every Hsl value should print a visible color swatch.
// Every function should print as a clickable OSC 8 link
// to its source location. The REPL is a hypertext document.
// DolDoc proved this in 2003. We just need escape sequences.
