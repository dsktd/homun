const std = @import("std");

const mount = @import("mount.zig");
const relay = @import("relay.zig");

const usage =
    \\usage: claude-ns mount <pid> <src> <dst> [--ro]
    \\       claude-ns unmount <pid> <dst>
    \\       claude-ns relay <pid> <inbound|outbound> <tcp|udp> <listen-port> <target-port>
    \\
;

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();

    const argv = init.minimal.args.toSlice(arena) catch return fail(error.OutOfMemory);
    if (argv.len < 2) {
        std.debug.print(usage, .{});
        return 2;
    }

    dispatch(arena, argv[1], argv[2..]) catch |err| return fail(err);
    return 0;
}

fn dispatch(arena: std.mem.Allocator, command: []const u8, args: []const [:0]const u8) !void {
    if (std.mem.eql(u8, command, "mount")) return mount.mount(args);
    if (std.mem.eql(u8, command, "unmount")) return mount.unmount(args);

    if (std.mem.eql(u8, command, "relay")) {
        const plain = try arena.alloc([]const u8, args.len);
        for (args, plain) |arg, *out| out.* = arg;
        return relay.run(plain);
    }

    return error.UnknownCommand;
}

fn fail(err: anyerror) u8 {
    std.debug.print("claude-ns: {s}\n", .{@errorName(err)});
    return 1;
}
