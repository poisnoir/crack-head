const std = @import("std");
const net = std.Io.net;
const Dir = std.Io.Dir;
const mad = @import("mad.zig");
const globals = @import("globals.zig");
const helper = @import("helper.zig");
const string = helper.string;
const print = std.debug.print;

// Wire shape spined expects as the first message on a node-registration
// connection — must match spined's own RegisterNodePayload (server.zig) and
// spine-go's registernodePayload (node.go) exactly: same two fields, same
// fixed-size string type, alphabetical field order for mad's wire format
// ("namespace_name" sorts before "node_name").
const RegisterNodePayload = struct {
    namespace_name: string,
    node_name: string,
};

pub const RegisterError = error{
    InvalidNamespace,
    NodeAlreadyRegistered,
    TooManyNodes,
    UnexpectedStatus,
};

// Wire shape for registering an entity (publisher/subscriber/service/service
// caller) on an already-registered node's connection — must match spined's
// namespace.zig RegisterEntityPayload and spine-go's node.go
// RegisterEntityPayload exactly.
const RegisterEntityPayload = struct {
    entity_name: string,
    entity_type: u8,
};

pub const EntityRegisterError = error{
    TooManyEntities,
    InvalidEntityType,
    EntityAlreadyRegistered,
    TooManyUnknownEntities,
    UnexpectedStatus,
};

pub const SubscribeError = error{
    PayloadTypeMismatch,
};

pub const ServiceCallError = error{
    PayloadTypeMismatch,
    CallFailed,
};

pub const Node = struct {
    namespace: []const u8,
    name: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,

    // null when spined isn't reachable at all — mirrors spine-go's
    // "local-only mode" fallback (node.go's CreateNode): a node still works
    // for purely local use, it just isn't registered anywhere and can't be
    // discovered by anything else.
    spined_conn: ?net.Stream,

    pub fn init(
        namespace: []const u8,
        name: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !Node {
        const addr = net.UnixAddress.init(globals.SPINED_PATH) catch |err| {
            print("spine: invalid spined path {s}: {any}\n", .{ globals.SPINED_PATH, err });
            return localOnly(namespace, name, io, allocator);
        };

        const conn = addr.connect(io) catch |err| {
            print("spine: could not connect to spined ({any}), operating in local-only mode\n", .{err});
            return localOnly(namespace, name, io, allocator);
        };

        registerNode(conn, io, namespace, name) catch |err| {
            conn.close(io);
            return err;
        };

        print("spine: node '{s}' registered in namespace '{s}'\n", .{ name, namespace });

        return .{
            .namespace = namespace,
            .name = name,
            .io = io,
            .allocator = allocator,
            .spined_conn = conn,
        };
    }

    pub fn deinit(self: *Node) void {
        if (self.spined_conn) |conn| {
            conn.close(self.io);
            self.spined_conn = null;
        }
    }

    // Subscribes to `topic`, decoding each published message as K. K must
    // match the publisher's payload type exactly — mad's type-fingerprint
    // handshake (see Subscriber(K).connect below) rejects the connection
    // otherwise, mirroring spine-go's Subscriber/Publisher pair.
    //
    // Heap-allocated (via self.allocator) rather than returned by value: the
    // returned Subscriber holds a buffered net.Stream.Reader whose buffer
    // slice points back into the Subscriber itself, so its address must
    // never change after connect() wires that reader up.
    //
    // BUGFIX: no deinit()/Close() here (or on any entity, Go side included) —
    // an entity is meant to live as long as its node does, same as a
    // long-running HTTP server doesn't get told to "stop" individual
    // handlers. Real cleanup for Subscriber/ServiceCaller specifically is
    // coming back later, deliberately designed rather than bolted on.
    pub fn subscribe(self: *Node, comptime K: type, topic: []const u8) !*Subscriber(K) {
        // if running locally, there's nothing to tell spined, but the
        // subscriber can still connect directly to the publisher's socket
        // by convention path (mirrors spine-go's registerToSpined no-op).
        try self.registerEntity(topic, globals.SUBSCRIBER_TYPE);

        const sub = try self.allocator.create(Subscriber(K));
        errdefer self.allocator.destroy(sub);

        try sub.connect(self.io, self.namespace, topic);
        return sub;
    }

    fn registerEntity(self: *Node, name: []const u8, entity_type: u8) !void {
        const conn = self.spined_conn orelse return;

        const payload = RegisterEntityPayload{
            .entity_name = try string.fromConst(name),
            .entity_type = entity_type,
        };

        var w_buf: [256]u8 = undefined;
        var r_buf: [256]u8 = undefined;
        var w = conn.writer(self.io, &w_buf);
        var r = conn.reader(self.io, &r_buf);

        const size = mad.getRequiredSize(RegisterEntityPayload);
        var msg_buf: [256]u8 = undefined;
        _ = mad.encode(RegisterEntityPayload, payload, msg_buf[0..size]);

        try w.interface.writeAll(msg_buf[0..size]);
        try w.interface.flush();

        const status = try r.interface.takeInt(u8, .big);
        return switch (status) {
            globals.OK_STATUS => {},
            globals.TOO_MANY_ENTITIES => EntityRegisterError.TooManyEntities,
            globals.INVALID_ENTITY_TYPE => EntityRegisterError.InvalidEntityType,
            globals.ENTITY_ALREADY_REGISTERED => EntityRegisterError.EntityAlreadyRegistered,
            globals.TOO_MANY_UNKNOWN_ENTITIES => EntityRegisterError.TooManyUnknownEntities,
            else => EntityRegisterError.UnexpectedStatus,
        };
    }

    // Publishes K values on `topic`. Mirrors spine-go's NewPublisher: registers
    // the entity with spined (no-op in local-only mode), then binds a listener
    // at the publisher's fixed convention socket path so subscribers can dial
    // in directly. Same heap-allocation reasoning as subscribe() above — the
    // returned Publisher's client list is mutated from a background accept
    // task, so its address must be stable.
    pub fn publish(self: *Node, comptime K: type, topic: []const u8) !*Publisher(K) {
        try self.registerEntity(topic, globals.PUBLISHER_TYPE);

        const p = try self.allocator.create(Publisher(K));
        errdefer self.allocator.destroy(p);

        try p.listen(self.io, self.namespace, topic);
        return p;
    }

    // Serves K->V requests on `name`. Mirrors spine-go's NewService /
    // NewThreadedService — they share an identical wire protocol
    // (service_common.go), so this one type is compatible with either.
    // handler is called once per request, possibly concurrently across
    // clients (each accepted connection gets its own io.concurrent task).
    pub fn newService(self: *Node, comptime K: type, comptime V: type, name: []const u8, handler: *const fn (K) anyerror!V) !*Service(K, V) {
        try self.registerEntity(name, globals.SERVICE_TYPE);

        const s = try self.allocator.create(Service(K, V));
        errdefer self.allocator.destroy(s);

        try s.listen(self.io, self.namespace, name, handler);
        return s;
    }

    // Calls the K->V service registered as `name`. Mirrors spine-go's
    // NewServiceCaller.
    pub fn newServiceCaller(self: *Node, comptime K: type, comptime V: type, name: []const u8) !*ServiceCaller(K, V) {
        try self.registerEntity(name, globals.SERVICE_CALLER_TYPE);

        const c = try self.allocator.create(ServiceCaller(K, V));
        errdefer self.allocator.destroy(c);
        // one-time init — dial() (called by connect(), including on later
        // reconnects) never touches this again; see dial()'s BUGFIX comment.
        c.lock = .init;

        try c.connect(self.io, self.namespace, name);
        return c;
    }
};

// Generic subscriber: connects directly to the publisher's unix socket
// (independent of spined — the socket path is a fixed convention), performs
// mad's type-fingerprint handshake, then decodes one K per next() call.
pub fn Subscriber(comptime K: type) type {
    return struct {
        io: std.Io,
        conn: net.Stream,
        namespace: []const u8,
        topic: []const u8,

        r_buf: [globals.MAX_PACKET_SIZE]u8 = undefined,
        reader: net.Stream.Reader = undefined,

        const Self = @This();

        const initial_backoff_ms: i64 = 100;
        const max_backoff_ms: i64 = 5000;

        // Retries the dial+handshake with exponential backoff (mirrors
        // spine-go's subscriber.go, which retries its connect() the same way
        // via cenkalti/backoff) — the publisher may not have started its
        // listener yet, or may be mid-restart, and a tight retry loop would
        // otherwise spin a core at 100% doing nothing but failing connects.
        fn connect(self: *Self, io: std.Io, namespace: []const u8, topic: []const u8) !void {
            var backoff_ms: i64 = initial_backoff_ms;

            while (true) {
                self.dial(io, namespace, topic) catch |err| {
                    // BUGFIX: a type mismatch is permanent — K is fixed at
                    // compile time by the caller, so retrying can never fix
                    // it. Only transient errors (publisher not up yet, etc.)
                    // should back off and retry.
                    if (err == SubscribeError.PayloadTypeMismatch) return err;

                    print("spine: failed to connect to publisher for topic '{s}' ({any}), retrying in {d}ms\n", .{ topic, err, backoff_ms });
                    try io.sleep(std.Io.Duration.fromMilliseconds(backoff_ms), .awake);
                    backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
                    continue;
                };
                return;
            }
        }

        fn dial(self: *Self, io: std.Io, namespace: []const u8, topic: []const u8) !void {
            var path_buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}{s}/{s}", .{ globals.PUBLISHER_SOCKET_DIR, namespace, topic });
            const addr = try net.UnixAddress.init(path);
            const conn = try addr.connect(io);

            self.* = .{
                .io = io,
                .conn = conn,
                .namespace = namespace,
                .topic = topic,
                .r_buf = undefined,
                .reader = undefined,
            };
            self.reader = conn.reader(io, &self.r_buf);

            var w_buf: [64]u8 = undefined;
            var w = conn.writer(io, &w_buf);
            try w.interface.writeAll(mad.code(K));
            try w.interface.flush();

            const status = try self.reader.interface.takeInt(u8, .big);
            if (status != globals.OK_STATUS) {
                conn.close(io);
                return SubscribeError.PayloadTypeMismatch;
            }

            print("spine: subscribed to topic '{s}'\n", .{topic});
        }

        // Blocks until the next published message arrives, then decodes it.
        //
        // BUGFIX: a read failure (publisher died/restarted) used to surface
        // straight to the caller as an error, unlike spine-go's Subscriber,
        // which reconnects transparently in its background goroutine and
        // just keeps Get() blocked until new data shows up. next() now does
        // the synchronous equivalent: on a read failure, reconnect (with the
        // same unlimited backoff as the initial connect) and retry the read,
        // rather than surfacing a transient disconnect as an error. Reading
        // has no side effects, so retrying here has none of the
        // at-most-once/idempotency concerns ServiceCaller.call() has.
        pub fn next(self: *Self) !K {
            const size = mad.getRequiredSize(K);
            while (true) {
                const msg = self.reader.interface.take(size) catch |err| {
                    print("spine: subscriber connection to topic '{s}' lost ({any}), reconnecting\n", .{ self.topic, err });
                    self.conn.close(self.io);
                    try self.connect(self.io, self.namespace, self.topic);
                    continue;
                };
                var out: K = undefined;
                _ = mad.decode(K, &out, msg);
                return out;
            }
        }
    };
}

// Generic publisher: binds a listener at the publisher's fixed convention
// socket path (independent of spined — subscribers dial in directly) and
// broadcasts each publish() call to every subscriber that has completed the
// mad type-fingerprint handshake.
pub fn Publisher(comptime K: type) type {
    comptime {
        if (mad.getRequiredSize(K) > globals.MAX_PACKET_SIZE) {
            @compileError("payload type too big for globals.MAX_PACKET_SIZE");
        }
    }

    return struct {
        io: std.Io,
        topic: []const u8,
        listener: net.Server,

        clients: [globals.MAX_SUBSCRIBERS_PER_PUBLISHER]net.Stream = undefined,
        clients_num: usize = 0,
        lock: std.Io.Mutex = .init,

        const Self = @This();

        fn listen(self: *Self, io: std.Io, namespace: []const u8, topic: []const u8) !void {
            var path_buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}{s}/{s}", .{ globals.PUBLISHER_SOCKET_DIR, namespace, topic });

            const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try Dir.cwd().createDirPath(io, dir);
            // stale socket file from a previous run of this publisher — ignore
            // if it isn't there.
            Dir.deleteFileAbsolute(io, path) catch {};

            const addr = try net.UnixAddress.init(path);
            const srv = try addr.listen(io, .{});

            self.* = .{
                .io = io,
                .topic = topic,
                .listener = srv,
                .clients = undefined,
                .clients_num = 0,
                .lock = .init,
            };

            print("spine: publisher listening on topic '{s}'\n", .{topic});

            _ = try io.concurrent(acceptLoop, .{self});
        }

        fn acceptLoop(self: *Self) void {
            while (true) {
                const conn = self.listener.accept(self.io) catch |err| {
                    print("spine: publisher accept failed for topic '{s}': {any}\n", .{ self.topic, err });
                    continue;
                };
                self.handshake(conn) catch |err| {
                    print("spine: subscriber handshake failed for topic '{s}': {any}\n", .{ self.topic, err });
                };
            }
        }

        // Reads the subscriber's mad type-fingerprint and rejects it if it
        // doesn't match K, mirroring spine-go's Publisher.registerSubscriber.
        fn handshake(self: *Self, conn: net.Stream) !void {
            var w_buf: [64]u8 = undefined;
            var r_buf: [64]u8 = undefined;
            var w = conn.writer(self.io, &w_buf);
            var r = conn.reader(self.io, &r_buf);

            const expected = mad.code(K);

            // BUGFIX: was `r.interface.take(expected.len)` — a fixed-length
            // read for however many bytes *our own* K's code happens to be.
            // A genuinely mismatched subscriber sends a *different* number of
            // bytes (a different K has a different code length) and then
            // just waits for the status reply, so take() blocked forever
            // waiting for bytes that would never come — a real deadlock, not
            // just a slow path. readVec does a single opportunistic read (like
            // Go's raw conn.Read) and hands back however many bytes actually
            // arrived, so a length mismatch is just a mismatch, not a hang.
            var code_buf: [64]u8 = undefined;
            var vecs: [1][]u8 = .{&code_buf};
            const n = r.interface.readVec(&vecs) catch {
                conn.close(self.io);
                return;
            };
            const msg = code_buf[0..n];

            if (!std.mem.eql(u8, msg, expected)) {
                w.interface.writeInt(u8, globals.ERROR_MISMATCH_PAYLOAD_CODE, .big) catch {};
                w.interface.flush() catch {};
                conn.close(self.io);
                return;
            }

            // BUGFIX: register the client *before* acking OK_STATUS, not
            // after. The old order let a subscriber see OK_STATUS — and so
            // return successfully from connect() — before it was actually in
            // `clients`, opening a window where a publish() racing right
            // after subscribe() returned could be missed entirely.
            try self.lock.lock(self.io);
            if (self.clients_num >= globals.MAX_SUBSCRIBERS_PER_PUBLISHER) {
                self.lock.unlock(self.io);
                conn.close(self.io);
                return;
            }
            self.clients[self.clients_num] = conn;
            self.clients_num += 1;
            const total = self.clients_num;
            self.lock.unlock(self.io);

            try w.interface.writeInt(u8, globals.OK_STATUS, .big);
            try w.interface.flush();

            print("spine: subscriber joined topic '{s}' ({d} total)\n", .{ self.topic, total });
        }

        // Broadcasts data to every currently-connected subscriber. Dead
        // connections (write failures) are dropped via swap-removal, the
        // same pattern spined's own cleanNode uses for its fixed-size arrays.
        pub fn publish(self: *Self, data: K) !void {
            const size = mad.getRequiredSize(K);
            var buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
            _ = mad.encode(K, data, buf[0..size]);

            try self.lock.lock(self.io);
            defer self.lock.unlock(self.io);

            var i: usize = 0;
            while (i < self.clients_num) {
                var w_buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
                var w = self.clients[i].writer(self.io, &w_buf);

                const failed = blk: {
                    w.interface.writeAll(buf[0..size]) catch break :blk true;
                    w.interface.flush() catch break :blk true;
                    break :blk false;
                };

                if (failed) {
                    self.clients[i].close(self.io);
                    self.clients_num -= 1;
                    self.clients[i] = self.clients[self.clients_num];
                } else {
                    i += 1;
                }
            }
        }
    };
}

// Generic RPC service: binds a listener at the service's fixed convention
// socket path and, for each connected caller, runs the key/value
// type-fingerprint handshake (service_common.go's establishConnection) then
// loops calling `handler` for every request. Each accepted connection gets
// its own io.concurrent task, so multiple callers are served independently —
// wire-compatible with both spine-go's Service and ThreadedService, which
// share the identical protocol in service_common.go and only differ
// internally in how Go schedules handler execution.
pub fn Service(comptime K: type, comptime V: type) type {
    comptime {
        if (mad.getRequiredSize(K) > globals.MAX_PACKET_SIZE) {
            @compileError("key type too big for globals.MAX_PACKET_SIZE");
        }
        if (mad.getRequiredSize(V) + 1 > globals.MAX_PACKET_SIZE) {
            @compileError("value type too big for globals.MAX_PACKET_SIZE");
        }
    }

    return struct {
        io: std.Io,
        name: []const u8,
        listener: net.Server,
        handler: *const fn (K) anyerror!V,

        const Self = @This();

        fn listen(self: *Self, io: std.Io, namespace: []const u8, name: []const u8, handler: *const fn (K) anyerror!V) !void {
            var path_buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}{s}/{s}", .{ globals.SERVICE_SOCKET_DIR, namespace, name });

            const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try Dir.cwd().createDirPath(io, dir);
            // stale socket file from a previous run of this service — ignore
            // if it isn't there.
            Dir.deleteFileAbsolute(io, path) catch {};

            const addr = try net.UnixAddress.init(path);
            const srv = try addr.listen(io, .{});

            self.* = .{
                .io = io,
                .name = name,
                .listener = srv,
                .handler = handler,
            };

            print("spine: service '{s}' listening\n", .{name});

            _ = try io.concurrent(acceptLoop, .{self});
        }

        fn acceptLoop(self: *Self) void {
            while (true) {
                const conn = self.listener.accept(self.io) catch |err| {
                    print("spine: service accept failed for '{s}': {any}\n", .{ self.name, err });
                    continue;
                };
                _ = self.io.concurrent(handleClient, .{ self, conn }) catch |err| {
                    print("spine: service '{s}' could not spawn client handler: {any}\n", .{ self.name, err });
                    conn.close(self.io);
                };
            }
        }

        // Reads the caller's key- then value-type fingerprints and rejects
        // the connection if either doesn't match. Mirrors spine-go's
        // establishConnection exactly, including the fact that a mismatch
        // gets *no* response byte at all — just a closed connection. A real
        // spine-go ServiceCaller only knows how to interpret that exact
        // shape of failure (an immediate read error, not a status byte), so
        // matching it here isn't optional if a Go caller needs to see the
        // same behavior talking to a Zig service.
        fn handshake(self: *Self, r: *net.Stream.Reader, w: *net.Stream.Writer) !bool {
            var key_code_buf: [64]u8 = undefined;
            var key_vecs: [1][]u8 = .{&key_code_buf};
            const kn = try r.interface.readVec(&key_vecs);
            if (!std.mem.eql(u8, key_code_buf[0..kn], mad.code(K))) return false;

            try w.interface.writeInt(u8, globals.OK_STATUS, .big);
            try w.interface.flush();

            var value_code_buf: [64]u8 = undefined;
            var value_vecs: [1][]u8 = .{&value_code_buf};
            const vn = try r.interface.readVec(&value_vecs);
            if (!std.mem.eql(u8, value_code_buf[0..vn], mad.code(V))) return false;

            try w.interface.writeInt(u8, globals.OK_STATUS, .big);
            try w.interface.flush();

            print("spine: caller connected to service '{s}'\n", .{self.name});
            return true;
        }

        fn handleClient(self: *Self, conn: net.Stream) void {
            defer conn.close(self.io);

            var r_buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
            var w_buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
            var r = conn.reader(self.io, &r_buf);
            var w = conn.writer(self.io, &w_buf);

            const matched = self.handshake(&r, &w) catch |err| {
                print("spine: service '{s}' handshake failed: {any}\n", .{ self.name, err });
                return;
            };
            if (!matched) return;

            const key_size = mad.getRequiredSize(K);
            const value_size = mad.getRequiredSize(V);

            while (true) {
                var req_buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
                var vecs: [1][]u8 = .{&req_buf};
                const n = r.interface.readVec(&vecs) catch return;

                // BUGFIX-adjacent: mad.decode has no bounds checking of its
                // own (it slices `input[0..byte_len]` directly, which panics
                // on a too-short buffer rather than returning an error), so
                // this guard has to happen before calling it, unlike
                // spine-go where mad-go's Decode returns "buffer too small".
                if (n < key_size) {
                    w.interface.writeInt(u8, globals.ERROR_SERIALIZER_ERROR_CODE, .big) catch return;
                    w.interface.flush() catch return;
                    continue;
                }

                var key: K = undefined;
                _ = mad.decode(K, &key, req_buf[0..key_size]);

                const value = self.handler(key) catch |err| {
                    print("spine: service '{s}' handler error: {any}\n", .{ self.name, err });
                    w.interface.writeInt(u8, globals.ERROR_SERVICE_ERROR_CODE, .big) catch return;
                    w.interface.flush() catch return;
                    continue;
                };

                var resp_buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
                resp_buf[0] = globals.OK_STATUS;
                _ = mad.encode(V, value, resp_buf[1 .. 1 + value_size]);

                w.interface.writeAll(resp_buf[0 .. 1 + value_size]) catch return;
                w.interface.flush() catch return;
            }
        }
    };
}

// Generic RPC caller: connects to a Service's fixed convention socket path,
// runs the same key/value type-fingerprint handshake, then sends requests
// and decodes responses one at a time. call() is mutex-guarded so concurrent
// callers on the same ServiceCaller can't interleave requests/responses on
// the single underlying connection — mirrors what spine-go's internal
// request channel + single run() goroutine achieves, just via a lock instead
// of a queue.
pub fn ServiceCaller(comptime K: type, comptime V: type) type {
    comptime {
        if (mad.getRequiredSize(K) > globals.MAX_PACKET_SIZE) {
            @compileError("key type too big for globals.MAX_PACKET_SIZE");
        }
        if (mad.getRequiredSize(V) + 1 > globals.MAX_PACKET_SIZE) {
            @compileError("value type too big for globals.MAX_PACKET_SIZE");
        }
    }

    return struct {
        io: std.Io,
        namespace: []const u8,
        name: []const u8,
        conn: net.Stream,
        is_connected: bool = false,

        r_buf: [globals.MAX_PACKET_SIZE]u8 = undefined,
        w_buf: [globals.MAX_PACKET_SIZE]u8 = undefined,
        reader: net.Stream.Reader = undefined,
        writer: net.Stream.Writer = undefined,
        lock: std.Io.Mutex = .init,

        const Self = @This();

        const initial_backoff_ms: i64 = 100;
        const max_backoff_ms: i64 = 5000;

        // Same backoff-retry reasoning as Subscriber.connect: a type
        // mismatch is permanent (K/V are fixed at compile time), so it
        // returns immediately instead of retrying forever.
        fn connect(self: *Self, io: std.Io, namespace: []const u8, name: []const u8) !void {
            var backoff_ms: i64 = initial_backoff_ms;

            while (true) {
                self.dial(io, namespace, name) catch |err| {
                    if (err == ServiceCallError.PayloadTypeMismatch) return err;

                    print("spine: failed to connect to service '{s}' ({any}), retrying in {d}ms\n", .{ name, err, backoff_ms });
                    try io.sleep(std.Io.Duration.fromMilliseconds(backoff_ms), .awake);
                    backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
                    continue;
                };
                return;
            }
        }

        // BUGFIX: this used to be a blanket `self.* = .{...}` literal that
        // included `.lock = .init`. That's fine for the very first connect
        // (self is freshly allocated, uninitialized memory), but dial() is
        // also called to reconnect from *inside* call() when is_connected is
        // false — and call() has already locked self.lock at that point.
        // Resetting it mid-call replaced the held lock with a fresh
        // *unlocked* one, so call()'s deferred unlock later found nothing
        // locked and Io.Mutex correctly panicked rather than silently
        // ignoring it. lock is a one-time thing, set by Node.newServiceCaller
        // before the first connect() — dial() must never touch it.
        fn dial(self: *Self, io: std.Io, namespace: []const u8, name: []const u8) !void {
            var path_buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}{s}/{s}", .{ globals.SERVICE_SOCKET_DIR, namespace, name });
            const addr = try net.UnixAddress.init(path);
            const conn = try addr.connect(io);

            self.io = io;
            self.namespace = namespace;
            self.name = name;
            self.conn = conn;
            self.is_connected = false;
            self.reader = conn.reader(io, &self.r_buf);
            self.writer = conn.writer(io, &self.w_buf);

            // BUGFIX-adjacent: a real spine-go service replies with *nothing
            // and closes the connection* on a type mismatch (see Service's
            // handshake comment) rather than a status byte — so a read that
            // errors out right after either handshake write means the same
            // thing here as an explicit non-OK status.
            try self.writer.interface.writeAll(mad.code(K));
            try self.writer.interface.flush();
            const key_status = self.reader.interface.takeInt(u8, .big) catch {
                conn.close(io);
                return ServiceCallError.PayloadTypeMismatch;
            };
            if (key_status != globals.OK_STATUS) {
                conn.close(io);
                return ServiceCallError.PayloadTypeMismatch;
            }

            try self.writer.interface.writeAll(mad.code(V));
            try self.writer.interface.flush();
            const value_status = self.reader.interface.takeInt(u8, .big) catch {
                conn.close(io);
                return ServiceCallError.PayloadTypeMismatch;
            };
            if (value_status != globals.OK_STATUS) {
                conn.close(io);
                return ServiceCallError.PayloadTypeMismatch;
            }

            self.is_connected = true;
            print("spine: connected to service '{s}'\n", .{name});
        }

        fn markDisconnected(self: *Self) void {
            self.is_connected = false;
            self.conn.close(self.io);
        }

        // BUGFIX: a mid-connection drop used to just surface as an error
        // forever after — nothing ever reconnected. Mirrors spine-go's
        // ServiceCaller.run(): if the last attempt marked the connection
        // dead, reconnect (unlimited backoff, same as the initial connect)
        // before trying this request. A failure *during* this request also
        // marks it dead so the *next* call reconnects first — this call
        // still returns its own error rather than silently retrying the same
        // request, since the request may have already taken effect
        // server-side by the time the failure is observed (unlike
        // Subscriber.next(), reading has no such idempotency concern).
        pub fn call(self: *Self, key: K) !V {
            try self.lock.lock(self.io);
            defer self.lock.unlock(self.io);

            if (!self.is_connected) {
                try self.connect(self.io, self.namespace, self.name);
            }

            const key_size = mad.getRequiredSize(K);
            var req_buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
            _ = mad.encode(K, key, req_buf[0..key_size]);

            self.writer.interface.writeAll(req_buf[0..key_size]) catch |err| {
                self.markDisconnected();
                return err;
            };
            self.writer.interface.flush() catch |err| {
                self.markDisconnected();
                return err;
            };

            const value_size = mad.getRequiredSize(V);
            var resp_buf: [globals.MAX_PACKET_SIZE]u8 = undefined;
            var vecs: [1][]u8 = .{&resp_buf};
            const n = self.reader.interface.readVec(&vecs) catch |err| {
                self.markDisconnected();
                return err;
            };

            if (n == 0 or n < 1 + value_size) {
                self.markDisconnected();
                return ServiceCallError.CallFailed;
            }

            const status = resp_buf[0];
            if (status != globals.OK_STATUS) {
                print("spine: service '{s}' call failed with status {d}\n", .{ self.name, status });
                return ServiceCallError.CallFailed;
            }

            var value: V = undefined;
            _ = mad.decode(V, &value, resp_buf[1 .. 1 + value_size]);
            return value;
        }
    };
}

fn localOnly(namespace: []const u8, name: []const u8, io: std.Io, allocator: std.mem.Allocator) Node {
    return .{
        .namespace = namespace,
        .name = name,
        .io = io,
        .allocator = allocator,
        .spined_conn = null,
    };
}

fn registerNode(conn: net.Stream, io: std.Io, namespace: []const u8, name: []const u8) !void {
    const payload = RegisterNodePayload{
        .namespace_name = try string.fromConst(namespace),
        .node_name = try string.fromConst(name),
    };

    var w_buf: [256]u8 = undefined;
    var r_buf: [256]u8 = undefined;
    var w = conn.writer(io, &w_buf);
    var r = conn.reader(io, &r_buf);

    const size = mad.getRequiredSize(RegisterNodePayload);
    var msg_buf: [256]u8 = undefined;
    _ = mad.encode(RegisterNodePayload, payload, msg_buf[0..size]);

    try w.interface.writeAll(msg_buf[0..size]);
    try w.interface.flush();

    const status = try r.interface.takeInt(u8, .big);
    return switch (status) {
        globals.OK_STATUS => {},
        globals.INVALID_NAMESPACE => RegisterError.InvalidNamespace,
        globals.NODE_ALREADY_REGISTERED => RegisterError.NodeAlreadyRegistered,
        globals.TOO_MANY_NODES => RegisterError.TooManyNodes,
        else => RegisterError.UnexpectedStatus,
    };
}

const testing = std.testing;

// Tests share one Io/allocator for the whole file instead of one per test:
// Publisher.listen() spawns an acceptLoop that runs forever on a background
// thread (there's no Close()/deinit() for entities — see the BUGFIX notes on
// Node.subscribe above), so tearing down a per-test std.Io.Threaded would
// mean joining a thread that's permanently blocked in accept(). Never
// deinit-ing here and letting the test process exit reclaim everything
// mirrors how every other part of this codebase already treats entity
// lifetime.
var test_threaded: std.Io.Threaded = undefined;
var test_arena: std.heap.ArenaAllocator = undefined;
var test_io_ready = false;

fn ensureTestIoReady() void {
    if (test_io_ready) return;
    // BUGFIX: default async_limit is cpu_count-1 — fine for the pub/sub
    // tests (one background accept-loop task each), but Service adds a
    // *second* forever-running task per test (one per accepted caller
    // connection, since ServiceCaller never closes its connection either).
    // Left at the default, enough service tests would eventually exhaust the
    // limit and make io.concurrent start failing. Set generously high so the
    // limit tracks "how many tests exist," not "how many cores this machine
    // has."
    test_threaded = .init(std.heap.page_allocator, .{
        .async_limit = .limited(256),
        .concurrent_limit = .limited(256),
    });
    test_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    test_io_ready = true;
}

fn testIo() std.Io {
    ensureTestIoReady();
    return test_threaded.io();
}

fn testAllocator() std.mem.Allocator {
    ensureTestIoReady();
    return test_arena.allocator();
}

test "pubsub: basic roundtrip" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "pubsub_test_basic_node", io, allocator);
    defer node.deinit();

    const publisher = try node.publish(u32, "pubsub_test_basic");
    const subscriber = try node.subscribe(u32, "pubsub_test_basic");

    try publisher.publish(777);
    try testing.expectEqual(@as(u32, 777), try subscriber.next());
}

test "pubsub: multiple subscribers all receive the same value" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "pubsub_test_multi_node", io, allocator);
    defer node.deinit();

    const publisher = try node.publish(i32, "pubsub_test_multi");

    const sub1 = try node.subscribe(i32, "pubsub_test_multi");
    const sub2 = try node.subscribe(i32, "pubsub_test_multi");
    const sub3 = try node.subscribe(i32, "pubsub_test_multi");

    try publisher.publish(42);

    try testing.expectEqual(@as(i32, 42), try sub1.next());
    try testing.expectEqual(@as(i32, 42), try sub2.next());
    try testing.expectEqual(@as(i32, 42), try sub3.next());
}

test "pubsub: multiple values arrive in order" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "pubsub_test_order_node", io, allocator);
    defer node.deinit();

    const publisher = try node.publish(u32, "pubsub_test_order");
    const subscriber = try node.subscribe(u32, "pubsub_test_order");

    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try publisher.publish(i);
    }

    i = 0;
    while (i < 50) : (i += 1) {
        try testing.expectEqual(i, try subscriber.next());
    }
}

test "pubsub: mismatched payload type is rejected, not retried forever" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "pubsub_test_mismatch_node", io, allocator);
    defer node.deinit();

    _ = try node.publish(u32, "pubsub_test_mismatch");

    const result = node.subscribe(f32, "pubsub_test_mismatch");
    try testing.expectError(SubscribeError.PayloadTypeMismatch, result);
}

const TestReading = struct {
    x: f32,
    y: f32,
};

test "pubsub: struct payload" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "pubsub_test_struct_node", io, allocator);
    defer node.deinit();

    const publisher = try node.publish(TestReading, "pubsub_test_struct");
    const subscriber = try node.subscribe(TestReading, "pubsub_test_struct");

    try publisher.publish(.{ .x = 1.5, .y = -2.25 });
    const got = try subscriber.next();

    try testing.expectEqual(@as(f32, 1.5), got.x);
    try testing.expectEqual(@as(f32, -2.25), got.y);
}

test "pubsub: dead subscriber is dropped from the client list" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "pubsub_test_dead_client_node", io, allocator);
    defer node.deinit();

    const publisher = try node.publish(u32, "pubsub_test_dead_client");

    {
        // this subscriber is only kept alive long enough to connect, then its
        // connection is closed — simulating a subscriber process that died.
        const doomed = try node.subscribe(u32, "pubsub_test_dead_client");
        doomed.conn.close(io);
    }

    const survivor = try node.subscribe(u32, "pubsub_test_dead_client");

    // first publish() after the dead client closed is what actually notices
    // the write failure and swap-removes it.
    try publisher.publish(1);
    _ = try survivor.next();

    try testing.expectEqual(@as(usize, 1), publisher.clients_num);
}

test "pubsub: subscriber reconnects after connection drop" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "pubsub_test_reconnect_node", io, allocator);
    defer node.deinit();

    const publisher = try node.publish(u32, "pubsub_test_reconnect");
    const subscriber = try node.subscribe(u32, "pubsub_test_reconnect");

    try publisher.publish(1);
    try testing.expectEqual(@as(u32, 1), try subscriber.next());

    // Simulate the connection dying by closing the *publisher's* accepted
    // copy of it (and forgetting it from clients so publish() never reuses
    // that same fd) — not the subscriber's own fd. Closing your own fd and
    // then reusing it is a real use-after-close bug (this Io backend panics
    // on it, correctly), not a stand-in for a remote disconnect. Closing the
    // *peer's* end and leaving the subscriber's own fd untouched is exactly
    // how a real disconnect gets observed: next()'s next read on its own
    // still-valid fd sees a genuine EOF/error, no unsafe fd reuse involved.
    publisher.clients[0].close(io);
    publisher.clients_num = 0;

    var future = io.async(Subscriber(u32).next, .{subscriber});

    // give next() a moment to notice the closed conn and reconnect before
    // publishing — dialing a local unix socket is fast but not instant.
    try io.sleep(std.Io.Duration.fromMilliseconds(200), .awake);
    try publisher.publish(2);

    try testing.expectEqual(@as(u32, 2), try future.await(io));
}

fn doubleHandler(input: u32) anyerror!u32 {
    return input * 2;
}

fn errorOnZeroHandler(input: u32) anyerror!u32 {
    if (input == 0) return error.ZeroNotAllowed;
    return input;
}

test "service: basic call" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "service_test_basic_node", io, allocator);
    defer node.deinit();

    _ = try node.newService(u32, u32, "service_test_basic", doubleHandler);
    const caller = try node.newServiceCaller(u32, u32, "service_test_basic");

    try testing.expectEqual(@as(u32, 42), try caller.call(21));
}

test "service: multiple sequential calls over the same caller" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "service_test_multi_node", io, allocator);
    defer node.deinit();

    _ = try node.newService(u32, u32, "service_test_multi", doubleHandler);
    const caller = try node.newServiceCaller(u32, u32, "service_test_multi");

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try testing.expectEqual(i * 2, try caller.call(i));
    }
}

test "service: handler error surfaces as CallFailed" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "service_test_error_node", io, allocator);
    defer node.deinit();

    _ = try node.newService(u32, u32, "service_test_error", errorOnZeroHandler);
    const caller = try node.newServiceCaller(u32, u32, "service_test_error");

    try testing.expectEqual(@as(u32, 5), try caller.call(5));
    try testing.expectError(ServiceCallError.CallFailed, caller.call(0));
}

test "service: mismatched key type is rejected, not retried forever" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "service_test_keymismatch_node", io, allocator);
    defer node.deinit();

    _ = try node.newService(u32, u32, "service_test_keymismatch", doubleHandler);

    const result = node.newServiceCaller(f32, u32, "service_test_keymismatch");
    try testing.expectError(ServiceCallError.PayloadTypeMismatch, result);
}

test "service: mismatched value type is rejected" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "service_test_valmismatch_node", io, allocator);
    defer node.deinit();

    _ = try node.newService(u32, u32, "service_test_valmismatch", doubleHandler);

    const result = node.newServiceCaller(u32, f32, "service_test_valmismatch");
    try testing.expectError(ServiceCallError.PayloadTypeMismatch, result);
}

test "service: caller reconnects when marked disconnected" {
    const io = testIo();
    const allocator = testAllocator();

    var node = try Node.init("common", "service_test_reconnect_node", io, allocator);
    defer node.deinit();

    _ = try node.newService(u32, u32, "service_test_reconnect", doubleHandler);
    const caller = try node.newServiceCaller(u32, u32, "service_test_reconnect");

    try testing.expectEqual(@as(u32, 2), try caller.call(1));

    // Simulate having detected a dead connection the way markDisconnected()
    // would after a real write/read failure, without actually touching the
    // fd: Service doesn't expose its accepted per-caller connections (unlike
    // Publisher's `clients`), so there's no equivalent of the pubsub
    // reconnect test's "close the peer's copy, not our own" trick available
    // here. This still exercises the exact branch that matters — call()
    // reconnecting before attempting the request when is_connected is false
    // — see readme.md's live cross-process verification for the real
    // socket-level failure path (killing and restarting an actual service).
    caller.is_connected = false;

    try testing.expectEqual(@as(u32, 6), try caller.call(3));
}
