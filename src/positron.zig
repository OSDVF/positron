const std = @import("std");

const zig_serve = @import("serve");
const log = std.log.scoped(.Positron);

/// A web browser window that one can interact with.
/// Uses a JSON RPC solution to talk to the browser window.
pub const View = opaque {
    const Self = @This();

    /// Creates a new webview instance. If `allow_debug` is set - developer tools will
    /// be enabled (if the platform supports them). `parent_window` parameter can be a
    /// pointer to the native window handle. If it's non-null - then child WebView
    /// is embedded into the given parent window. Otherwise a new window is created.
    /// Depending on the platform, a GtkWindow, NSWindow or HWND pointer can be
    /// passed here.
    pub fn create(allow_debug: bool, parent_window: ?*anyopaque) !*Self {
        return webview_create(@intFromBool(allow_debug), parent_window) orelse return error.WebviewError;
    }

    /// Destroys a webview and closes the native window.
    pub fn destroy(self: *Self) void {
        webview_destroy(self);
    }

    /// Runs the main loop until it's terminated. After this function exits - you
    /// must destroy the webview.
    pub fn run(self: *Self) void {
        webview_run(self);
    }

    /// Stops the main loop. It is safe to call this function from another other
    /// background thread.
    pub fn terminate(self: *Self) void {
        webview_terminate(self);
    }

    /// Posts a function to be executed on the main thread. You normally do not need
    /// to call this function, unless you want to tweak the native window.
    pub fn dispatch(self: *Self, func: *const fn (*Self, ?*const anyopaque) callconv(.C) void, arg: ?*anyopaque) void {
        webview_dispatch(self, func, arg);
    }

    // Returns a native window handle pointer. When using GTK backend the pointer
    // is GtkWindow pointer, when using Cocoa backend the pointer is NSWindow
    // pointer, when using Win32 backend the pointer is HWND pointer.
    pub fn getWindow(self: *Self) *anyopaque {
        return webview_get_window(self) orelse @panic("missing native window!");
    }

    /// Updates the title of the native window. Must be called from the UI thread.
    pub fn setTitle(self: *Self, title: [:0]const u8) void {
        webview_set_title(self, title.ptr);
    }

    /// Updates native window size.
    pub fn setSize(self: *Self, width: u16, height: u16, hint: SizeHint) void {
        webview_set_size(self, width, height, @intFromEnum(hint));
    }

    /// Navigates webview to the given URL. URL may be a data URI, i.e.
    /// `data:text/text,<html>...</html>`. It is often ok not to url-encode it
    /// properly, webview will re-encode it for you.
    pub fn navigate(self: *Self, url: [:0]const u8) void {
        webview_navigate(self, url.ptr);
    }

    /// Injects JavaScript code at the initialization of the new page. Every time
    /// the webview will open a the new page - this initialization code will be
    /// executed. It is guaranteed that code is executed before window.onload.
    pub fn init(self: *Self, js: [:0]const u8) void {
        webview_init(self, js.ptr);
    }

    /// Evaluates arbitrary JavaScript code. Evaluation happens asynchronously, also
    /// the result of the expression is ignored. Use RPC bindings if you want to
    /// receive notifications about the results of the evaluation.
    pub fn eval(self: *Self, js: [*:0]const u8) void {
        webview_eval(self, js);
    }

    /// Binds a callback so that it will appear under the given name as a
    /// global JavaScript function. Internally it uses webview_init(). Callback
    /// receives a request string and a user-provided argument pointer. Request
    /// string is a JSON array of all the arguments passed to the JavaScript
    /// function.
    pub fn bindRaw(self: *Self, name: [:0]const u8, context: anytype, comptime callback: fn (ctx: @TypeOf(context), seq: [:0]const u8, req: [:0]const u8) void) void {
        const Context = @TypeOf(context);
        const Binder = struct {
            fn c_callback(seq: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.C) void {
                callback(
                    @as(Context, @ptrCast(arg)),
                    std.mem.sliceTo(seq, 0),
                    std.mem.sliceTo(req, 0),
                );
            }
        };

        webview_bind(self, name.ptr, Binder.c_callback, context);
    }

    /// Binds a callback so that it will appear under the given name as a
    /// global JavaScript function. The callback will be called with `context` as the first parameter,
    /// all other parameters must be deserializable to JSON. The return value might be a error union,
    /// in which case the error is returned to the JS promise. Otherwise, a normal result is serialized to
    /// JSON and then sent back to JS.
    pub fn bind(self: *Self, name: [:0]const u8, comptime callback: anytype, context: @typeInfo(@TypeOf(callback)).Fn.params[0].type.?) void {
        const Fn = @TypeOf(callback);
        const function_info = @typeInfo(Fn).Fn;

        if (function_info.params.len < 1)
            @compileError("Function must take at least the context argument!");

        const ReturnType = function_info.return_type orelse @compileError("Function must be non-generic!");
        const return_info = @typeInfo(ReturnType);

        const Context = @TypeOf(context);

        const Binder = struct {
            fn getWebView(ctx: Context) *Self {
                if (Context == *Self)
                    return ctx;
                return ctx.getWebView();
            }

            fn expectArrayStart(stream: *std.json.Scanner) !void {
                const tok = (try stream.peekNextTokenType());
                if (tok != .array_begin)
                    return error.InvalidJson;
                _ = try stream.next();
            }

            fn expectArrayEnd(stream: *std.json.Scanner) !void {
                const tok = (try stream.peekNextTokenType());
                if (tok != .array_end)
                    return error.InvalidJson;
                _ = try stream.next();
            }

            fn errorResponse(view: *Self, seq: [:0]const u8, err: anyerror) void {
                var buffer: [64]u8 = undefined;
                const err_str = std.fmt.bufPrint(&buffer, "\"{s}\"\x00", .{@errorName(err)}) catch @panic("error name too long!");

                view.@"return"(seq, .{ .failure = err_str[0 .. err_str.len - 1 :0] });
            }

            fn successResponse(view: *Self, seq: [:0]const u8, value: anytype) void {
                if (@TypeOf(value) != void) {
                    var buf = std.ArrayList(u8).init(std.heap.c_allocator);
                    defer buf.deinit();

                    std.json.stringify(value, .{}, buf.writer()) catch |err| {
                        return errorResponse(view, seq, err);
                    };

                    buf.append(0) catch |err| {
                        return errorResponse(view, seq, err);
                    };

                    const str = buf.items;

                    view.@"return"(seq, .{ .success = str[0 .. str.len - 1 :0] });
                } else {
                    view.@"return"(seq, .{ .success = "" });
                }
            }

            fn c_callback(seq0: [*c]const u8, req0: [*c]const u8, arg: ?*anyopaque) callconv(.C) void {
                const cb_context = @as(Context, @ptrCast(@alignCast(arg)));

                const view = getWebView(cb_context);

                const seq = std.mem.sliceTo(seq0, 0);
                const req = std.mem.sliceTo(req0, 0);

                // std.log.info("invocation: {*} seq={s} req={s}", .{
                //     view, seq, req,
                // });

                const ArgType = std.meta.ArgsTuple(Fn);

                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();

                var parsed_args: ArgType = undefined;
                parsed_args[0] = cb_context;

                var allocator = arena.allocator();
                var json_parser = std.json.Scanner.initCompleteInput(allocator, req);
                {
                    expectArrayStart(&json_parser) catch |err| {
                        log.err("parser start: {}", .{err});
                        return errorResponse(view, seq, err);
                    };

                    comptime var i = 1;
                    inline while (i < function_info.params.len) : (i += 1) {
                        var arena2 = allocator.create(std.heap.ArenaAllocator) catch |err| return errorResponse(view, seq, err);
                        errdefer allocator.destroy(arena2);
                        arena2.* = std.heap.ArenaAllocator.init(allocator);
                        errdefer arena2.deinit();
                        const Type = @TypeOf(parsed_args[i]);
                        const parsed = std.json.innerParse(Type, arena2.allocator(), &json_parser, .{
                            .duplicate_field_behavior = .use_first,
                            .ignore_unknown_fields = false,
                            .allocate = .alloc_if_needed,
                            .max_value_len = json_parser.input.len,
                        }) catch |err| {
                            if (@errorReturnTrace()) |trace|
                                std.debug.dumpStackTrace(trace.*);
                            log.err("parsing argument {d}: {}", .{ i, err });
                            return errorResponse(view, seq, err);
                        };
                        parsed_args[i] = parsed;
                    }

                    expectArrayEnd(&json_parser) catch |err| {
                        log.err("parser end: {}", .{err});
                        return errorResponse(view, seq, err);
                    };
                }

                const result = @call(.auto, callback, parsed_args);

                // std.debug.print("result: {}\n", .{result});

                if (return_info == .ErrorUnion) {
                    if (result) |value| {
                        return successResponse(view, seq, value);
                    } else |err| {
                        return errorResponse(view, seq, err);
                    }
                } else {
                    successResponse(view, seq, result);
                }
            }
        };

        webview_bind(self, name.ptr, Binder.c_callback, context);
    }

    /// Allows to return a value from the native binding. Original request pointer
    /// must be provided to help internal RPC engine match requests with responses.
    /// If status is zero - result is expected to be a valid JSON result value.
    /// If status is not zero - result is an error JSON object.
    pub fn @"return"(self: *Self, seq: [:0]const u8, result: ReturnValue) void {
        switch (result) {
            .success => |res_text| webview_return(self, seq.ptr, 0, res_text.ptr),
            .failure => |res_text| webview_return(self, seq.ptr, 1, res_text.ptr),
        }
    }

    // C Binding:

    extern fn webview_create(debug: c_int, window: ?*anyopaque) ?*Self;
    extern fn webview_destroy(w: *Self) void;
    extern fn webview_run(w: *Self) void;
    extern fn webview_terminate(w: *Self) void;
    extern fn webview_dispatch(w: *Self, func: ?*const fn (*Self, ?*anyopaque) callconv(.C) void, arg: ?*anyopaque) void;
    extern fn webview_get_window(w: *Self) ?*anyopaque;
    extern fn webview_set_title(w: *Self, title: [*:0]const u8) void;
    extern fn webview_set_size(w: *Self, width: c_int, height: c_int, hints: c_int) void;
    extern fn webview_navigate(w: *Self, url: [*:0]const u8) void;
    extern fn webview_init(w: *Self, js: [*:0]const u8) void;
    extern fn webview_eval(w: *Self, js: [*:0]const u8) void;
    extern fn webview_bind(w: *Self, name: [*:0]const u8, func: *const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.C) void, arg: ?*anyopaque) void;
    extern fn webview_return(w: *Self, seq: [*:0]const u8, status: c_int, result: [*c]const u8) void;
};

pub const SizeHint = enum(c_int) {
    /// Width and height are default size
    none = 0,
    /// Width and height are minimum bounds
    min = 1,
    /// Width and height are maximum bounds
    max = 2,
    /// Window size can not be changed by a user
    fixed = 3,
};

pub const ReturnValue = union(enum) {
    success: [:0]const u8,
    failure: [:0]const u8,
};

test {
    _ = View.create;
    _ = View.destroy;
    _ = View.run;
    _ = View.terminate;
    _ = View.dispatch;
    _ = View.getWindow;
    _ = View.setTitle;
    _ = View.setSize;
    _ = View.navigate;
    _ = View.init;
    _ = View.eval;
    _ = View.bind;
    _ = View.bindRaw;
    _ = View.@"return";
}

pub const Provider = struct {
    const Self = @This();

    pub const Route = struct {
        pub const Error = error{OutOfMemory} || zig_serve.HttpResponse.WriteError;

        const GenericPointer = opaque {};
        const RouteHandler = *const fn (*Provider, *Route, *zig_serve.HttpContext) Error!void;

        arena: std.heap.ArenaAllocator,
        prefix: [:0]const u8,

        handler: RouteHandler,
        context: *GenericPointer,
        pub fn getContext(self: Route, comptime T: type) *T {
            return @as(*T, @ptrCast(@alignCast(self.context)));
        }

        pub fn deinit(self: *Route) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub const EmbedDir = struct {
        address: []const u8,
        path: []const u8,
        resolveMime: *const fn (path: []const u8) []const u8,
        fn hasAddress(self: *const @This(), address: []const u8) bool {
            return std.ascii.startsWithIgnoreCase(address, self.address);
        }
        fn resolveAddressPath(self: *const @This(), allocator: std.mem.Allocator, address: []const u8) !?[]const u8 {
            if (self.hasAddress(address)) {
                return try std.fs.path.join(allocator, &.{ self.path, address[self.address.len..] });
            }
            return null;
        }
    };

    allocator: std.mem.Allocator,
    server: zig_serve.HttpListener,
    base_url: []const u8,
    not_found_text: ?[]const u8 = null,
    routes: std.ArrayList(Route),
    /// List of directories that contain runtime CWD-relative file tree with provided content
    embedded: std.ArrayList(EmbedDir),
    allowed_origins: ?std.BufSet = null,

    pub fn create(allocator: std.mem.Allocator, port: u16) !*Self {
        const provider = try allocator.create(Self);
        errdefer allocator.destroy(provider);

        provider.* = Self{
            .allocator = allocator,
            .base_url = undefined,
            .embedded = std.ArrayList(EmbedDir).init(allocator),
            .server = undefined,
            .routes = std.ArrayList(Route).init(allocator),
        };
        errdefer provider.routes.deinit();

        provider.server = try zig_serve.HttpListener.init(allocator);
        errdefer provider.server.deinit();

        try provider.server.addEndpoint(zig_serve.IP.loopback_v4, port);

        try provider.server.start();

        const endpoint = try provider.server.bindings.items[0].socket.?.getLocalEndPoint();

        provider.base_url = try std.fmt.allocPrint(provider.allocator, "http://127.0.0.1:{d}", .{endpoint.port});
        errdefer provider.allocator.free(provider.base_url);

        return provider;
    }

    pub fn destroy(self: *Self) void {
        self.server.deinit();
        if (self.allowed_origins) |*ao| {
            ao.deinit();
        }

        for (self.routes.items) |*route| {
            route.deinit();
        }
        self.routes.deinit();
        self.embedded.deinit();
        self.allocator.free(self.base_url);
    }

    fn compareRoute(_: void, lhs: Route, rhs: Route) bool {
        return std.ascii.lessThanIgnoreCase(lhs.prefix, rhs.prefix);
    }

    fn sortRoutes(self: *Self) void {
        std.sort.sort(Route, self.routes.items, {}, compareRoute);
    }

    fn defaultRoute(self: *Provider, route: *Route, context: *zig_serve.HttpContext) Route.Error!void {
        _ = route;

        try context.response.setHeader("Content-Type", "text/html");
        try context.response.setStatusCode(.not_found);

        var writer = try context.response.writer();
        try writer.writeAll(self.not_found_text orelse
            \\<!doctype html>
            \\<html lang="en">
            \\  <head>
            \\    <meta charset="UTF-8">
            \\  </head>
            \\  <body>
            \\    <p>The requested page was not found!</p>
            \\  </body>
            \\</html>
        );
        try writer.writeByte('\n');
    }

    pub fn addRoute(self: *Self, abs_path: []const u8) !*Route {
        std.debug.assert(abs_path[0] == '/');

        const route = try self.routes.addOne();
        errdefer _ = self.routes.pop();

        route.* = Route{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .prefix = undefined,
            .handler = defaultRoute,
            .context = undefined,
        };
        errdefer route.deinit();

        route.prefix = try std.fmt.allocPrintZ(route.arena.allocator(), "{s}{s}", .{ self.base_url, abs_path });

        return route;
    }

    pub fn addFile(self: *Self, abs_path: []const u8, mime_type: []const u8, path: []const u8) !void {
        const route = try self.addRoute(abs_path);

        const Handler = struct {
            mime_type: []const u8,
            path: []const u8,
            allowed_origins: ?std.BufSet,

            fn handle(provider: *Provider, r: *Route, context: *zig_serve.HttpContext) Route.Error!void {
                const handler = r.getContext(@This());
                if (std.fs.cwd().openFile(handler.path, .{})) |file| {
                    defer file.close();
                    const content = file.readToEndAlloc(provider.allocator, 10 * 1024 * 1024) catch |err| {
                        try context.response.setHeader("Content-Type", "text/plain");
                        try context.response.setStatusCode(.internal_server_error);
                        var writer = try context.response.writer();
                        try writer.print("Could not read file {s}: {}\n", .{ handler.path, err });
                        return;
                    };
                    try context.response.setHeader("Content-Type", handler.mime_type);
                    defer provider.allocator.free(content);
                    var writer = try context.response.writer();
                    try writer.writeAll(content);
                } else |err| {
                    try context.response.setHeader("Content-Type", "text/plain");
                    try context.response.setStatusCode(.not_found);
                    var writer = try context.response.writer();
                    try writer.print("Could not open file {s}: {}\n", .{ handler.path, err });
                }
            }
        };

        const handler = try route.arena.allocator().create(Handler);
        handler.* = Handler{
            .mime_type = try route.arena.allocator().dupe(u8, mime_type),
            .path = path,
            .allowed_origins = self.allowed_origins,
        };

        route.handler = Handler.handle;
        route.context = @as(*Route.GenericPointer, @ptrCast(handler));
    }

    pub fn addContent(self: *Self, abs_path: []const u8, mime_type: []const u8, contents: []const u8) !void {
        const route = try self.addRoute(abs_path);

        const Handler = struct {
            mime_type: []const u8,
            contents: []const u8,
            allowed_origins: ?std.BufSet,

            fn handle(_: *Provider, r: *Route, context: *zig_serve.HttpContext) Route.Error!void {
                const handler = r.getContext(@This());

                try context.response.setHeader("Content-Type", handler.mime_type);

                var writer = try context.response.writer();
                try writer.writeAll(handler.contents);
            }
        };

        const handler = try route.arena.allocator().create(Handler);
        handler.* = Handler{
            .mime_type = try route.arena.allocator().dupe(u8, mime_type),
            .contents = try route.arena.allocator().dupe(u8, contents),
            .allowed_origins = self.allowed_origins,
        };

        route.handler = Handler.handle;
        route.context = @as(*Route.GenericPointer, @ptrCast(handler));
    }

    pub fn addContentDeflatedNoAlloc(self: *Self, abs_path: []const u8, mime_type: []const u8, contents: []const u8) !void {
        const route = try self.addRoute(abs_path);

        const Handler = struct {
            mime_type: []const u8,
            contents: []const u8,
            allowed_origins: ?std.BufSet,

            fn handle(_: *Provider, r: *Route, context: *zig_serve.HttpContext) Route.Error!void {
                const handler = r.getContext(@This());

                try context.response.setHeader("Content-Type", handler.mime_type);
                try context.response.setHeader("Content-Encoding", "deflate");

                var writer = try context.response.writer();
                try writer.writeAll(handler.contents);
            }
        };

        const handler = try route.arena.allocator().create(Handler);
        handler.* = Handler{
            .mime_type = mime_type,
            .contents = contents,
            .allowed_origins = self.allowed_origins,
        };

        route.handler = Handler.handle;
        route.context = @as(*Route.GenericPointer, @ptrCast(handler));
    }

    fn addAccessControl(self: *Self, context: *zig_serve.HttpContext) !void {
        if (self.allowed_origins) |ao| {
            if (context.request.headers.get("Origin")) |o| {
                if (ao.contains(o)) {
                    try context.response.setHeader("Access-Control-Allow-Origin", o);
                }
            }
        }
    }

    /// Returns the full URI for `abs_path`
    pub fn getUriAlloc(self: *Self, abs_path: []const u8) !?[:0]const u8 {
        std.debug.assert(abs_path[0] == '/');
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.prefix[self.base_url.len..], abs_path))
                return try self.allocator.dupeZ(u8, route.prefix);
        }
        for (self.embedded.items) |embedded_dir| {
            if (embedded_dir.hasAddress(abs_path)) {
                return try std.fmt.allocPrintZ(self.allocator, "{s}{s}", .{ self.base_url, abs_path });
            }
        }
        return null;
    }

    pub fn run(self: *Self) !void {
        while (try self.server.getContext()) |ctx| {
            defer ctx.deinit();

            self.handleRequest(ctx) catch |err| {
                log.warn("failed request: {s}", .{@errorName(err)});
            };
        }
    }

    fn handleRequest(self: *Self, ctx: *zig_serve.HttpContext) !void {
        try self.addAccessControl(ctx);
        var path = ctx.request.url;
        if (std.mem.indexOfScalar(u8, path, '?')) |index| {
            path = path[0..index];
        }

        var best_match: ?*Route = null;
        for (self.routes.items) |*route| {
            if (std.mem.startsWith(u8, path, route.prefix[self.base_url.len..])) {
                if (best_match == null or best_match.?.prefix.len < route.prefix.len) {
                    best_match = route;
                }
            }
        }

        if (best_match) |route| {
            try route.handler(self, route, ctx);
        } else {
            for (self.embedded.items) |embedded_dir| {
                if (try embedded_dir.resolveAddressPath(self.allocator, path)) |sub_path| {
                    defer self.allocator.free(sub_path);
                    if (std.fs.cwd().openFile(sub_path, .{})) |file| {
                        defer file.close();
                        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
                            try ctx.response.setHeader("Content-Type", "text/plain");
                            try ctx.response.setStatusCode(.internal_server_error);
                            var writer = try ctx.response.writer();
                            try writer.print("Could not read file {s}: {}\n", .{ path, err });
                            return;
                        };
                        try ctx.response.setHeader("Content-Type", embedded_dir.resolveMime(path));
                        defer self.allocator.free(content);
                        var writer = try ctx.response.writer();
                        try writer.writeAll(content);
                        return;
                    } else |err| {
                        try ctx.response.setHeader("Content-Type", "text/plain");
                        try ctx.response.setStatusCode(.not_found);
                        var writer = try ctx.response.writer();
                        try writer.print("Could not open file {s}: {}\n", .{ path, err });
                        return;
                    }
                }
            }

            try defaultRoute(self, undefined, ctx);
        }
    }
};
