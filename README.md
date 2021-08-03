# ⚛ Positron

A Zig binding to the [webview](https://github.com/webview/webview) library. Make Zig applications with a nice HTML5 frontend a reality!

## Usage

```zig
const std = @import("std");
const wv = @import("positron");

pub fn main() !void {
    const view = try wv.View.create(false, null);
    defer view.destroy();

    view.setTitle("Webview Example");
    view.setSize(480, 320, .none);

    view.navigate("https://ziglang.org");
    view.run();
}
```

## Example

The example is a small, two-view chat application that transfers data bidirectionally between backend and frontend.

Log in with `ziggy`/`love` and you can send messages, no real server there though!

You can build the example with `zig build` and run it with `zig build run`.

## Contributing

This library is in a early state and is very WIP. Still, feel free to contribute with PRs, or use it. Just don't assume a stable API.