const std = @import("std");
const definition = @import("../provider/definition.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("secret.zig");

/// Owned parsed session. Secrets are scrubbed before releasing the JSON arena.
pub const Session = struct {
    provider_id: []const u8,
    token_endpoint: []const u8,
    client_id: []const u8,
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_at_ms: i64,
    account: ?[]const u8 = null,
};
pub const Owned = struct {
    parsed: std.json.Parsed(Session),
    pub fn deinit(self: *Owned) void {
        @memset(@constCast(self.parsed.value.access_token), 0);
        if (self.parsed.value.refresh_token) |value| @memset(@constCast(value), 0);
        self.parsed.deinit();
        self.* = undefined;
    }
};

/// Holds the provider's process-shared mutation lock across refresh/logout.
pub const Store = struct {
    dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
    pub fn open(provider_id: []const u8) !Store {
        try definition.validate_id(provider_id);
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) };
        defer home_dir.close();
        var profile = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, ".ffx");
        defer profile.close();
        return open_at(&profile, provider_id);
    }
    fn open_at(profile: *io_mod.VerifiedDir, provider_id: []const u8) !Store {
        try definition.validate_id(provider_id);
        var root = try io_mod.openOrCreateVerifiedPrivateDir(profile, "provider-oauth");
        defer root.close();
        var dir = try io_mod.openOrCreateVerifiedPrivateDir(&root, provider_id);
        errdefer dir.close();
        const lock = try io_mod.acquireTimedAdvisoryLock(&dir, "auth.lock", 2000);
        return .{ .dir = dir, .lock = lock };
    }
    pub fn deinit(self: *Store) void {
        self.lock.release();
        self.dir.close();
    }
    pub fn load(self: *Store, alloc: std.mem.Allocator) !?Owned {
        var file = self.dir.dir.openFile(io_mod.getIo(), "session.json", .{ .follow_symlinks = false, .resolve_beneath = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.InsecureOAuthSession;
        const bytes = try io_mod.readFileToEnd(alloc, &file, 64 * 1024);
        defer secret.zeroAndFree(alloc, bytes);
        return .{ .parsed = try std.json.parseFromSlice(Session, alloc, bytes, .{ .allocate = .alloc_always }) };
    }
    pub fn save(self: *Store, alloc: std.mem.Allocator, session: Session) !void {
        var writer = std.Io.Writer.Allocating.init(alloc);
        defer {
            @memset(writer.written(), 0);
            writer.deinit();
        }
        try std.json.Stringify.value(session, .{}, &writer.writer);
        try io_mod.durableReplaceVerified(alloc, &self.dir, "session.json", writer.written());
    }
    pub fn remove(self: *Store) !void {
        self.dir.dir.deleteFile(io_mod.getIo(), "session.json") catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        try io_mod.syncVerifiedDir(self.dir.dir);
    }
};

test "generic OAuth storage isolates provider sessions and deletes locally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var profile = io_mod.VerifiedDir{ .dir = tmp.dir };
    var first = try Store.open_at(&profile, "alpha");
    defer first.deinit();
    var second = try Store.open_at(&profile, "beta");
    defer second.deinit();
    try first.save(std.testing.allocator, .{ .provider_id = "alpha", .token_endpoint = "https://example.com/token", .client_id = "client", .access_token = "secret", .expires_at_ms = 5000 });
    try std.testing.expect((try second.load(std.testing.allocator)) == null);
    var loaded = (try first.load(std.testing.allocator)).?;
    defer loaded.deinit();
    try std.testing.expectEqualStrings("secret", loaded.parsed.value.access_token);
    try first.remove();
    try std.testing.expect((try first.load(std.testing.allocator)) == null);
    try std.testing.expectError(error.InvalidProviderId, Store.open_at(&profile, "../alpha"));
}
