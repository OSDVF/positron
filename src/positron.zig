const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz");
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
    pub fn dispatch(self: *Self, func: *const fn (*Self, ?*const anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
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

    pub fn setIcon(self: *Self, icon: [:0]const u8) void {
        webview_set_icon(self, icon.ptr);
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
            fn c_callback(seq: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
                callback(
                    @as(Context, @alignCast(@ptrCast(arg))),
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
    pub fn bind(self: *Self, name: [:0]const u8, comptime callback: anytype, context: @typeInfo(@TypeOf(callback)).@"fn".params[0].type.?) void {
        const Fn = @TypeOf(callback);
        const function_info = @typeInfo(Fn).@"fn";

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

            fn c_callback(seq0: [*c]const u8, req0: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
                const cb_context: Context = @alignCast(@ptrCast(arg));

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

                if (return_info == .error_union) {
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
    extern fn webview_dispatch(w: *Self, func: ?*const fn (*Self, ?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;
    extern fn webview_get_window(w: *Self) ?*anyopaque;
    extern fn webview_set_title(w: *Self, title: [*:0]const u8) void;
    extern fn webview_set_size(w: *Self, width: c_int, height: c_int, hints: c_int) void;
    extern fn webview_set_icon(w: *Self, icon: [*:0]const u8) void;
    extern fn webview_navigate(w: *Self, url: [*:0]const u8) void;
    extern fn webview_init(w: *Self, js: [*:0]const u8) void;
    extern fn webview_eval(w: *Self, js: [*:0]const u8) void;
    extern fn webview_bind(w: *Self, name: [*:0]const u8, func: *const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;
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
    _ = View.setIcon;
    _ = View.navigate;
    _ = View.init;
    _ = View.eval;
    _ = View.bind;
    _ = View.bindRaw;
    _ = View.@"return";
}

fn HandlerWrapper(comptime T: type) type {
    return struct {
        allowed_origins: ?std.BufSet = null,
        base_url: []const u8,
        cwd: std.fs.Dir,
        not_found_text: ?[]const u8 = null,

        wrapped: T,

        fn addAccessControl(self: *@This(), req: *httpz.Request, res: *httpz.Response) !void {
            if (self.allowed_origins) |ao| {
                if (req.header("origin")) |o| {
                    if (ao.contains(o)) {
                        res.header("access-control-allow-origin", o);
                    }
                }
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (std.meta.hasFn(T, "deinit")) {
                T.deinit(self, allocator);
            }

            if (self.allowed_origins) |*ao| {
                ao.deinit();
            }

            allocator.free(self.base_url);
        }

        pub fn dispatch(self: *@This(), action: httpz.Action(*@This()), req: *httpz.Request, res: *httpz.Response) !void {
            try self.addAccessControl(req, res);

            if (std.meta.hasFn(T, "dispatch")) {
                if (!try T.dispatch(self, action, req, res)) return;
            }
            if (std.meta.hasFn(T, "additionalAction")) {
                try T.additionalAction(self, req, res);
            }

            return action(self, req, res);
        }

        pub fn provider(self: *@This()) *Provider(T) {
            return @fieldParentPtr("handler", self);
        }

        fn notFound(self: *@This(), req: *httpz.Request, res: *httpz.Response) !void {
            res.header("content-type", "text/html");
            if (std.meta.hasFn(T, "additionalAction")) {
                try T.additionalAction(self, req, res);
            }
            res.status = std.http.Status.not_found;

            var writer = try res.writer();
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
    };
}

pub fn Provider(comptime Handler: type) type {
    const FileContext = struct {
        max_file_size: usize = 20 * 1024 * 1024,
        mime_type: []const u8,
        path: []const u8,

        fn handle(_: *const anyopaque, req: *httpz.Request, res: *httpz.Response) !void {
            const context: *const @This() = @alignCast(@ptrCast(req.route_data));

            if (std.fs.cwd().openFile(context.path, .{})) |file| {
                defer file.close();
                res.body = file.readToEndAlloc(res.arena, context.max_file_size) catch |err| {
                    res.header("content-type", "text/plain");
                    res.status = std.http.Status.internal_server_error;
                    try std.fmt.format(res.writer(), "Could not read file {s}: {}\n", .{ context.path, err });
                    return;
                };
                res.header("content-type", context.mime_type);
            } else |err| {
                res.header("content-type", "text/plain");
                res.status = std.http.Status.not_found;
                var writer = try res.writer();
                try writer.print("Could not open file {s}: {}\n", .{ context.path, err });
            }
        }
    };

    const wrapped = HandlerWrapper(Handler);
    const dummy = httpz.Server(*wrapped);
    const _dummy: dummy = undefined;

    return struct {
        const Self = @This();
        pub const Router = @TypeOf(_dummy._router);
        pub const RouterConfig = @typeInfo(@TypeOf(Server.router)).@"fn".params[1].type.?;
        pub const Server = httpz.Server(*WrappedHandler);
        pub const WrappedHandler = wrapped;

        /// arena that contains all routes contexts
        arena: std.heap.ArenaAllocator,
        dir: *DirContext,
        handler: WrappedHandler,
        router: *Router,
        server: Server,

        pub fn create(allocator: std.mem.Allocator, config: httpz.Config, router_config: RouterConfig, handler: Handler) !*Self {
            var arena = std.heap.ArenaAllocator.init(allocator);
            const arena_allocator = arena.allocator();

            const provider = try arena_allocator.create(Self);
            errdefer arena_allocator.destroy(provider);

            provider.* = Self{
                .arena = undefined,
                .dir = try allocator.create(DirContext),
                .handler = WrappedHandler{
                    .base_url = undefined,
                    .cwd = try std.fs.cwd().openDir(".", .{}),
                    .wrapped = handler,
                },
                .server = undefined,
                .router = undefined,
            };

            provider.server = try Server.init(allocator, config, &provider.handler);
            provider.dir.* = DirContext{
                .embedded = std.ArrayList(DirContext.EmbedDir).init(allocator),
            };

            errdefer {
                provider.server.stop();
                provider.server.deinit();
            }

            provider.router = try provider.server.router(router_config);
            provider.router.get("/*", DirContext.handle, .{ .data = provider.dir });

            provider.server.handler.base_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{
                config.address orelse "127.0.0.1",
                config.port orelse 5882, // The default values must be snyced with the default values defined by httpz
            });
            errdefer arena_allocator.free(provider.handler.base_url);
            provider.arena = arena;

            return provider;
        }

        pub fn destroy(self: *Self) void {
            self.server.stop();
            self.server.allocator.destroy(self.dir);
            self.server.handler.deinit(self.server.allocator);
            self.server.deinit();
            self.arena.deinit();
        }

        pub fn addFile(self: *Self, abs_path: []const u8, mime_type: []const u8, path: []const u8) !void {
            const allocator = self.arena.allocator();
            const context = try allocator.create(FileContext);
            context.* = .{
                .mime_type = mime_type,
                .path = path,
            };

            try self.router.tryGet(abs_path, FileContext.handle, .{
                .data = context,
            });
        }

        pub fn addContent(self: *Self, abs_path: []const u8, mime_type: []const u8, contents: []const u8) !void {
            const allocator = self.arena.allocator();
            const context = try allocator.create(ContentContext);

            context.* = ContentContext{
                .mime_type = try allocator.dupe(u8, mime_type),
                .contents = try allocator.dupe(u8, contents),
            };

            return self.router.get(abs_path, ContentContext.handle, .{
                .data = context,
            });
        }

        pub fn addContentNoAlloc(self: *Self, abs_path: []const u8, mime_type: []const u8, contents: []const u8) !*ContentContext {
            const allocator = self.arena.allocator();
            const context = try allocator.create(ContentContext);

            context.* = ContentContext{
                .mime_type = mime_type,
                .contents = contents,
            };

            try self.router.tryGet(abs_path, ContentContext.handle, .{
                .data = context,
            });
            return context;
        }

        /// Returns the full URI for `abs_path`
        pub fn getUriAlloc(self: *Self, abs_path: []const u8) !?[:0]const u8 {
            std.debug.assert(abs_path[0] == '/');
            const allocator = self.arena.allocator();
            return try std.fmt.allocPrintZ(allocator, "{s}{s}", .{ self.server.handler.base_url, abs_path });
            // TODO return only really routable urls
        }

        /// this is blocking on Windows
        pub fn run(self: *Self) !void {
            try self.server.listen();
        }

        fn fdIsValid(fd: std.posix.fd_t) bool {
            return if (builtin.os.tag == .windows)
                true
            else
                std.posix.system.fcntl(fd, std.posix.F.GETFD) != -1;
        }

        pub const ContentContext = struct {
            mime_type: []const u8,
            contents: []const u8,
            additional_handler: ?*const fn (*Self, *httpz.Request, *httpz.Response) void = null,

            pub fn handle(self: *WrappedHandler, req: *httpz.Request, res: *httpz.Response) !void {
                const context: *const ContentContext = @alignCast(@ptrCast(req.route_data));

                res.header("content-type", context.mime_type);
                if (context.additional_handler) |handler| handler(self.provider(), req, res);
                res.body = context.contents;
            }
        };

        pub const DirContext = struct {
            /// List of directories that contain runtime CWD-relative file tree with provided content
            embedded: std.ArrayList(EmbedDir),
            max_file_size: usize = 20 * 1024 * 1024,

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

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.embedded.deinit(allocator);
            }

            pub fn handle(handler: *WrappedHandler, req: *httpz.Request, res: *httpz.Response) !void {
                const context: *const DirContext = @alignCast(@ptrCast(req.route_data));

                for (context.embedded.items) |embedded_dir| {
                    if (try embedded_dir.resolveAddressPath(res.arena, req.url.path)) |sub_path| {
                        defer res.arena.free(sub_path);
                        if (fdIsValid(handler.cwd.fd)) { // is not valid after closed application
                            if (handler.cwd.openFile(sub_path, .{})) |file| {
                                defer file.close();
                                res.body = file.readToEndAlloc(res.arena, context.max_file_size) catch |err| {
                                    res.header("content-type", "text/plain");
                                    res.status = @intFromEnum(std.http.Status.internal_server_error);
                                    var writer = res.writer();
                                    try writer.print("Could not read file {s}: {}\n", .{ req.url.path, err });
                                    return;
                                };
                                res.header("content-type", embedded_dir.resolveMime(req.url.path));

                                return;
                            } else |_| {}
                        }
                    }
                }
            }
        };
    };
}
