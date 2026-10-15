const std = @import("std");
const linux = std.os.linux;

const Direction = enum { inbound, outbound };
const Proto = enum { tcp, udp };

const udp_idle_seconds = 60;
const udp_max_sessions = 256;
const buffer_size = 65536;

const loopback = 0x7f000001;

pub fn run(args: []const []const u8) !void {
    if (args.len != 5) return error.Usage;

    const pid = std.fmt.parseInt(u32, args[0], 10) catch return error.InvalidPid;
    const direction = std.meta.stringToEnum(Direction, args[1]) orelse return error.Usage;
    const proto = std.meta.stringToEnum(Proto, args[2]) orelse return error.Usage;
    const listen_port = std.fmt.parseInt(u16, args[3], 10) catch return error.InvalidPort;
    const target_port = std.fmt.parseInt(u16, args[4], 10) catch return error.InvalidPort;
    if (listen_port == 0 or target_port == 0) return error.InvalidPort;

    const container_ns = try openContainerNs(pid);
    defer _ = linux.close(container_ns);

    const listener = switch (direction) {
        .inbound => try bindLoopback(proto, listen_port),
        .outbound => try bindInside(container_ns, proto, listen_port),
    };

    if (direction == .inbound) try enter(container_ns);

    const target = address(target_port);

    switch (proto) {
        .tcp => try serveTcp(listener, target),
        .udp => try serveUdp(listener, target),
    }
}

const Bound = struct {
    result: anyerror!i32 = error.Unexpected,
};

fn bindInside(ns: i32, proto: Proto, port: u16) !i32 {
    var bound: Bound = .{};

    const thread = try std.Thread.spawn(.{}, bindThread, .{ ns, proto, port, &bound });
    thread.join();

    return bound.result;
}

fn bindThread(ns: i32, proto: Proto, port: u16, bound: *Bound) void {
    enter(ns) catch |err| {
        bound.result = err;
        return;
    };

    bound.result = bindLoopback(proto, port);
}

fn serveTcp(listener: i32, target: linux.sockaddr.in) !void {
    _ = try check(linux.listen(listener, 128));

    while (true) {
        const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN, .CONNABORTED => continue,
            .MFILE, .NFILE, .NOBUFS, .NOMEM => {
                backoff();
                continue;
            },
            else => _ = try check(rc),
        }
        const client: i32 = @intCast(try check(rc));

        const upstream = connectTcp(target) catch {
            _ = linux.close(client);
            continue;
        };

        const thread = std.Thread.spawn(.{}, pipeTcp, .{ client, upstream }) catch {
            _ = linux.close(client);
            _ = linux.close(upstream);
            continue;
        };
        thread.detach();
    }
}

fn connectTcp(target: linux.sockaddr.in) !i32 {
    const fd: i32 = @intCast(try check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);

    _ = try check(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in)));
    return fd;
}

fn pipeTcp(a: i32, b: i32) void {
    defer _ = linux.close(a);
    defer _ = linux.close(b);

    var buf: [buffer_size]u8 = undefined;
    var fds = [_]linux.pollfd{
        .{ .fd = a, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = b, .events = linux.POLL.IN, .revents = 0 },
    };
    var open: u8 = 2;

    while (open > 0) {
        const rc = linux.poll(&fds, fds.len, -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return;

        for (&fds, 0..) |*pfd, i| {
            if (pfd.fd < 0 or pfd.revents == 0) continue;

            const peer = if (i == 0) b else a;
            const n = linux.read(pfd.fd, &buf, buf.len);

            if (linux.errno(n) != .SUCCESS) return;

            if (n == 0) {
                _ = linux.shutdown(peer, linux.SHUT.WR);
                pfd.fd = -1;
                open -= 1;
                continue;
            }

            if (!writeAll(peer, buf[0..n])) return;
        }
    }
}

fn writeAll(fd: i32, data: []const u8) bool {
    var rest = data;
    while (rest.len > 0) {
        const n = linux.sendto(fd, rest.ptr, rest.len, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return false;
        rest = rest[n..];
    }
    return true;
}

const Session = struct {
    client: linux.sockaddr.in,
    fd: i32,
    seen: i64,
};

fn serveUdp(listener: i32, target: linux.sockaddr.in) !void {
    var sessions: [udp_max_sessions]Session = undefined;
    var count: usize = 0;

    var fds: [udp_max_sessions + 1]linux.pollfd = undefined;
    var buf: [buffer_size]u8 = undefined;

    while (true) {
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        for (sessions[0..count], fds[1 .. count + 1]) |s, *pfd| {
            pfd.* = .{ .fd = s.fd, .events = linux.POLL.IN, .revents = 0 };
        }

        const rc = linux.poll(&fds, @intCast(count + 1), 1000);
        if (linux.errno(rc) == .INTR) continue;
        _ = try check(rc);

        const now = seconds();

        for (sessions[0..count], fds[1 .. count + 1]) |*s, pfd| {
            if (pfd.revents == 0) continue;

            const n = linux.recvfrom(s.fd, &buf, buf.len, 0, null, null);
            if (linux.errno(n) != .SUCCESS) continue;

            s.seen = now;
            _ = linux.sendto(listener, &buf, n, 0, @ptrCast(&s.client), @sizeOf(linux.sockaddr.in));
        }

        if (fds[0].revents != 0) {
            var from: linux.sockaddr.in = undefined;
            var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const n = linux.recvfrom(listener, &buf, buf.len, 0, @ptrCast(&from), &len);

            if (linux.errno(n) == .SUCCESS) {
                if (findOrOpen(&sessions, &count, from, target, now)) |s| {
                    s.seen = now;
                    _ = linux.write(s.fd, &buf, n);
                }
            }
        }

        var i: usize = 0;
        while (i < count) {
            if (now - sessions[i].seen < udp_idle_seconds) {
                i += 1;
                continue;
            }

            _ = linux.close(sessions[i].fd);
            count -= 1;
            sessions[i] = sessions[count];
        }
    }
}

fn findOrOpen(sessions: []Session, count: *usize, client: linux.sockaddr.in, target: linux.sockaddr.in, now: i64) ?*Session {
    for (sessions[0..count.*]) |*s| {
        if (s.client.addr == client.addr and s.client.port == client.port) return s;
    }

    if (count.* == sessions.len) return null;

    const fd = connectUdp(target) catch return null;

    sessions[count.*] = .{ .client = client, .fd = fd, .seen = now };
    count.* += 1;
    return &sessions[count.* - 1];
}

fn connectUdp(target: linux.sockaddr.in) !i32 {
    const fd: i32 = @intCast(try check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);

    _ = try check(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in)));
    return fd;
}

fn bindLoopback(proto: Proto, port: u16) !i32 {
    const kind: u32 = switch (proto) {
        .tcp => linux.SOCK.STREAM,
        .udp => linux.SOCK.DGRAM,
    };

    const fd: i32 = @intCast(try check(linux.socket(linux.AF.INET, kind | linux.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);

    if (proto == .tcp) {
        const one: c_int = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
    }

    const addr = address(port);
    _ = try check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    return fd;
}

fn address(port: u16) linux.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, loopback),
    };
}

fn openContainerNs(pid: u32) !i32 {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/proc/{d}/ns/net", .{pid});

    return @intCast(try check(linux.open(path, .{ .CLOEXEC = true }, 0)));
}

fn enter(ns: i32) !void {
    _ = try check(linux.setns(ns, linux.CLONE.NEWNET));
}

fn backoff() void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
}

fn seconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec;
}

fn check(rc: usize) !usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .PERM => error.PermissionDenied,
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .INVAL => error.InvalidArgument,
        .ADDRINUSE => error.AddressInUse,
        .CONNREFUSED => error.ConnectionRefused,
        .NOSYS => error.Unsupported,
        else => |e| {
            std.debug.print("claude-ns: {s}\n", .{@tagName(e)});
            std.process.exit(1);
        },
    };
}
