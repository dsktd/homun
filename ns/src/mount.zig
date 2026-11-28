const std = @import("std");
const linux = std.os.linux;

const OPEN_TREE_CLONE = 1;
const OPEN_TREE_CLOEXEC = 0o2000000;
const AT_RECURSIVE = 0x8000;
const AT_EMPTY_PATH = 0x1000;
const MOVE_MOUNT_F_EMPTY_PATH = 0x4;
const MOUNT_ATTR_RDONLY = 0x1;
const MNT_DETACH = 0x2;

const MountAttr = extern struct {
    attr_set: u64,
    attr_clr: u64,
    propagation: u64,
    userns_fd: u64,
};

pub fn mount(args: []const [:0]const u8) !void {
    if (args.len < 3 or args.len > 4) return error.Usage;

    const readonly = args.len == 4;
    if (readonly and !std.mem.eql(u8, args[3], "--ro")) return error.Usage;

    const pid = try parsePid(args[0]);
    const src = try absolute(args[1]);
    const dst = try absolute(args[2]);

    const tree = try check(linux.syscall3(
        .open_tree,
        @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr(src.ptr),
        OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_RECURSIVE,
    ));
    const tree_fd: i32 = @intCast(tree);
    const is_dir = try isDirectory(tree_fd);

    if (readonly) {
        var attr = std.mem.zeroes(MountAttr);
        attr.attr_set = MOUNT_ATTR_RDONLY;

        _ = try check(linux.syscall5(
            .mount_setattr,
            tree,
            @intFromPtr(""),
            AT_EMPTY_PATH | AT_RECURSIVE,
            @intFromPtr(&attr),
            @sizeOf(MountAttr),
        ));
    }

    try enter(pid);

    try makeParents(dst);
    if (is_dir) try makeDir(dst) else try makeFile(dst);

    _ = try check(linux.syscall5(
        .move_mount,
        tree,
        @intFromPtr(""),
        @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr(dst.ptr),
        MOVE_MOUNT_F_EMPTY_PATH,
    ));
}

pub fn unmount(args: []const [:0]const u8) !void {
    if (args.len != 2) return error.Usage;

    const pid = try parsePid(args[0]);
    const dst = try absolute(args[1]);

    try enter(pid);
    _ = try check(linux.umount2(dst.ptr, MNT_DETACH));
}

fn enter(pid: u32) !void {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/proc/{d}/ns/mnt", .{pid});

    const ns = try check(linux.open(path.ptr, .{ .CLOEXEC = true }, 0));
    defer _ = linux.close(@intCast(ns));

    _ = try check(linux.setns(@intCast(ns), linux.CLONE.NEWNS));
}

fn isDirectory(fd: i32) !bool {
    var st: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", AT_EMPTY_PATH, .{ .TYPE = true }, &st));
    return linux.S.ISDIR(st.mode);
}

fn makeParents(path: [:0]const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;

    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;

        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        try makeDir(buf[0..i :0]);
    }
}

fn makeDir(path: [:0]const u8) !void {
    const rc = linux.mkdirat(linux.AT.FDCWD, path.ptr, 0o755);
    if (linux.errno(rc) == .EXIST) return;
    _ = try check(rc);
}

fn makeFile(path: [:0]const u8) !void {
    const fd = try check(linux.open(path.ptr, .{ .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0o644));
    _ = linux.close(@intCast(fd));
}

fn absolute(path: [:0]const u8) ![:0]const u8 {
    if (path.len == 0 or path[0] != '/') return error.Usage;
    return path;
}

fn parsePid(arg: []const u8) !u32 {
    return std.fmt.parseInt(u32, arg, 10) catch error.InvalidPid;
}

fn check(rc: usize) !usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .PERM => error.PermissionDenied,
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .INVAL => error.InvalidArgument,
        .BUSY => error.DeviceBusy,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NOSYS => error.Unsupported,
        .XDEV => error.CrossDevice,
        else => |e| {
            std.debug.print("claude-ns: {s}\n", .{@tagName(e)});
            std.process.exit(1);
        },
    };
}
