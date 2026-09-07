const std = @import("std");
const definition = @import("../provider/definition.zig");
const io_mod = @import("../shared/io.zig");
const oauth = @import("oauth.zig");
const transport_mod = @import("oauth_transport.zig");
const secret = @import("secret.zig");
pub const session_store = @import("generic_oauth_session.zig");
const Allocator = std.mem.Allocator;

/// Borrows the definition and transport context for the entire operation.
pub const Adapter = struct {
    provider: definition.Definition,
    transport: transport_mod.Provider,

    pub fn validate(self: Adapter) !void {
        try self.provider.validate();
        switch (self.provider.auth.kind) {
            .oauth_device, .oauth_browser, .oauth_authorization_code => {},
            else => return error.UnsupportedOAuthAdapter,
        }
    }

    pub fn start_device(self: Adapter, alloc: Allocator, cancel: *std.atomic.Value(bool)) !Device {
        try self.validate();
        if (self.provider.auth.kind != .oauth_device) return error.OAuthFlowMismatch;
        const scope = try std.mem.join(alloc, " ", self.provider.auth.scopes);
        defer alloc.free(scope);
        var response = try self.request(alloc, self.provider.auth.device_authorization_endpoint.?, &.{ .{ "client_id", self.provider.auth.client_id.? }, .{ "scope", scope } }, cancel);
        defer response.deinit(alloc);
        var auth = try oauth.parseDeviceAuthorization(alloc, response.body);
        errdefer auth.deinit(alloc);
        if (auth.interval <= 0 or auth.expires_in <= 0) return error.InvalidOAuthResponse;
        return .{ .identity = self.identity(), .authorization = auth, .expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), auth.expires_in), .next_poll_ms = io_mod.milliTimestamp() +| (auth.interval *| 1000) };
    }

    /// Call on a timer. null means pending; slow_down increases subsequent intervals.
    /// A returned owned token set is persisted before it is handed to the caller.
    pub fn poll_device(self: Adapter, alloc: Allocator, device: *Device, cancel: *std.atomic.Value(bool)) !?oauth.TokenSet {
        try check_cancel(cancel);
        if (!std.mem.eql(u8, &device.identity, &self.identity())) return error.OAuthConfigurationChanged;
        const now = io_mod.milliTimestamp();
        if (now >= device.expires_at_ms) return error.OAuthDeviceExpired;
        if (now < device.next_poll_ms) return null;
        device.next_poll_ms = now +| (device.authorization.interval *| 1000);
        var response = self.request(alloc, self.provider.auth.token_endpoint.?, &.{ .{ "client_id", self.provider.auth.client_id.? }, .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }, .{ "device_code", device.authorization.device_code } }, cancel) catch |err| switch (err) {
            error.AuthorizationPending => return null,
            error.SlowDown => {
                device.authorization.interval +|= 5;
                device.next_poll_ms = now +| (device.authorization.interval *| 1000);
                return null;
            },
            else => return err,
        };
        defer response.deinit(alloc);
        var token = try oauth.parseTokenSet(alloc, response.body);
        errdefer token.deinit(alloc);
        try self.persist(alloc, token, cancel);
        return token;
    }

    pub fn start_browser(self: Adapter, alloc: Allocator, cancel: *std.atomic.Value(bool)) !Browser {
        try self.validate();
        try check_cancel(cancel);
        if (self.provider.auth.kind == .oauth_device) return error.OAuthFlowMismatch;
        const verifier = try random_secret(alloc);
        errdefer secret.zeroAndFree(alloc, verifier);
        const state = try random_secret(alloc);
        errdefer secret.zeroAndFree(alloc, state);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        var challenge: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
        const scope = try std.mem.join(alloc, " ", self.provider.auth.scopes);
        defer alloc.free(scope);
        const query = try form(alloc, &.{ .{ "client_id", self.provider.auth.client_id.? }, .{ "response_type", "code" }, .{ "redirect_uri", self.provider.auth.redirect_uri.? }, .{ "scope", scope }, .{ "state", state }, .{ "code_challenge", &challenge }, .{ "code_challenge_method", "S256" } });
        defer alloc.free(query);
        return .{ .identity = self.identity(), .verifier = verifier, .state = state, .url = try std.fmt.allocPrint(alloc, "{s}?{s}", .{ self.provider.auth.authorization_endpoint.?, query }) };
    }

    /// The caller owns the callback listener and supplies decoded code/state exactly once.
    pub fn exchange_browser(self: Adapter, alloc: Allocator, browser: *Browser, code: []const u8, state: []const u8, cancel: *std.atomic.Value(bool)) !void {
        try check_cancel(cancel);
        if (!std.mem.eql(u8, &browser.identity, &self.identity())) return error.OAuthConfigurationChanged;
        if (browser.consumed) return error.OAuthCallbackAlreadyUsed;
        if (state.len != browser.state.len or !std.crypto.timing_safe.eql([43]u8, state[0..43].*, browser.state[0..43].*)) return error.InvalidOAuthState;
        if (code.len == 0) return error.InvalidOAuthCallback;
        browser.consumed = true;
        var response = try self.request(alloc, self.provider.auth.token_endpoint.?, &.{ .{ "client_id", self.provider.auth.client_id.? }, .{ "grant_type", "authorization_code" }, .{ "code", code }, .{ "redirect_uri", self.provider.auth.redirect_uri.? }, .{ "code_verifier", browser.verifier } }, cancel);
        defer response.deinit(alloc);
        var token = try oauth.parseTokenSet(alloc, response.body);
        defer token.deinit(alloc);
        try self.persist(alloc, token, cancel);
    }

    fn persist(self: Adapter, alloc: Allocator, token: oauth.TokenSet, cancel: *std.atomic.Value(bool)) !void {
        try check_cancel(cancel);
        var store = try session_store.Store.open(self.provider.id);
        defer store.deinit();
        try check_cancel(cancel);
        try store.save(alloc, self.make_session(token));
    }

    fn make_session(self: Adapter, token: oauth.TokenSet) session_store.Session {
        return .{ .provider_id = self.provider.id, .client_id = self.provider.auth.client_id.?, .token_endpoint = self.provider.auth.token_endpoint.?, .access_token = token.access_token, .refresh_token = token.refresh_token, .expires_at_ms = io_mod.milliTimestamp() +| (token.expires_in *| 1000) };
    }

    /// Returns an owned access token; caller must scrub and free it.
    pub fn load_access(self: Adapter, alloc: Allocator, cancel: *std.atomic.Value(bool)) !?[]u8 {
        try self.validate();
        try check_cancel(cancel);
        var store = try session_store.Store.open(self.provider.id);
        defer store.deinit();
        var stored = (try store.load(alloc)) orelse return null;
        defer stored.deinit();
        const current = stored.parsed.value;
        try self.check_identity(current);
        if (current.expires_at_ms -| 60_000 > io_mod.milliTimestamp()) return try alloc.dupe(u8, current.access_token);
        const refresh = current.refresh_token orelse return error.OAuthLoginRequired;
        var response = self.request(alloc, self.provider.auth.token_endpoint.?, &.{ .{ "client_id", self.provider.auth.client_id.? }, .{ "grant_type", "refresh_token" }, .{ "refresh_token", refresh } }, cancel) catch |err| {
            if (err == error.OAuthInvalidGrant) try store.remove();
            return err;
        };
        defer response.deinit(alloc);
        var token = try oauth.parseTokenSet(alloc, response.body);
        defer token.deinit(alloc);
        var renewed = self.make_session(token);
        if (renewed.refresh_token == null) renewed.refresh_token = refresh;
        renewed.account = current.account;
        try check_cancel(cancel);
        try store.save(alloc, renewed);
        return try alloc.dupe(u8, token.access_token);
    }

    fn identity(self: Adapter) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ self.provider.id, self.provider.auth.client_id orelse "", self.provider.auth.token_endpoint orelse "", self.provider.auth.authorization_endpoint orelse "", self.provider.auth.device_authorization_endpoint orelse "", self.provider.auth.redirect_uri orelse "" }) |value| {
            hash.update(value);
            hash.update("\x00");
        }
        return hash.finalResult();
    }

    fn check_identity(self: Adapter, session: session_store.Session) !void {
        if (!std.mem.eql(u8, session.provider_id, self.provider.id) or !std.mem.eql(u8, session.client_id, self.provider.auth.client_id.?) or !std.mem.eql(u8, session.token_endpoint, self.provider.auth.token_endpoint.?)) return error.OAuthConfigurationChanged;
    }

    pub fn status(self: Adapter, alloc: Allocator) !Status {
        try self.validate();
        var store = try session_store.Store.open(self.provider.id);
        defer store.deinit();
        var stored = (try store.load(alloc)) orelse return .{};
        defer stored.deinit();
        try self.check_identity(stored.parsed.value);
        return .{ .exists = true, .expires_at_ms = stored.parsed.value.expires_at_ms, .expired = stored.parsed.value.expires_at_ms <= io_mod.milliTimestamp(), .account = if (stored.parsed.value.account) |account| try alloc.dupe(u8, account) else null };
    }

    /// Always remove local secrets even if remote revocation fails.
    pub fn logout(self: Adapter, alloc: Allocator, cancel: *std.atomic.Value(bool)) !Logout {
        try self.validate();
        var store = try session_store.Store.open(self.provider.id);
        defer store.deinit();
        var stored = (try store.load(alloc)) orelse return .{};
        defer stored.deinit();
        try store.remove();
        var result = Logout{ .removed = true };
        if (self.provider.auth.revocation_endpoint) |endpoint| {
            self.check_identity(stored.parsed.value) catch {
                result.revocation_failed = true;
                return result;
            };
            const current = stored.parsed.value;
            var response = self.request(alloc, endpoint, &.{ .{ "client_id", self.provider.auth.client_id.? }, .{ "token", current.refresh_token orelse current.access_token }, .{ "token_type_hint", if (current.refresh_token != null) "refresh_token" else "access_token" } }, cancel) catch {
                result.revocation_failed = true;
                return result;
            };
            response.deinit(alloc);
        }
        return result;
    }

    fn request(self: Adapter, alloc: Allocator, url: []const u8, fields: []const [2][]const u8, cancel: *std.atomic.Value(bool)) !transport_mod.Response {
        try check_cancel(cancel);
        const payload = try form(alloc, fields);
        defer secret.zeroAndFree(alloc, payload);
        var response = try self.transport.execute(alloc, .{ .method = .post_form, .url = url, .payload = payload, .cancel_flag = cancel, .deadline = .{ .raw = .fromNanoseconds(@as(i96, io_mod.milliTimestamp() +| 15_000) * 1_000_000), .clock = .real } });
        errdefer response.deinit(alloc);
        try check_cancel(cancel);
        if (response.disposition == .rejected) {
            const parsed = std.json.parseFromSlice(struct { @"error": []const u8 }, alloc, response.body, .{ .ignore_unknown_fields = true }) catch return error.OAuthRequestRejected;
            defer parsed.deinit();
            const name = parsed.value.@"error";
            if (std.mem.eql(u8, name, "authorization_pending")) return error.AuthorizationPending;
            if (std.mem.eql(u8, name, "slow_down")) return error.SlowDown;
            if (std.mem.eql(u8, name, "invalid_grant")) return error.OAuthInvalidGrant;
            if (std.mem.eql(u8, name, "access_denied")) return error.OAuthAccessDenied;
            if (std.mem.eql(u8, name, "expired_token")) return error.OAuthDeviceExpired;
            return error.OAuthRequestRejected;
        }
        return response;
    }
};

pub const Device = struct {
    identity: [32]u8,
    authorization: oauth.DeviceAuthorization,
    expires_at_ms: i64,
    next_poll_ms: i64,
    pub fn deinit(self: *Device, alloc: Allocator) void {
        self.authorization.deinit(alloc);
    }
};
pub const Browser = struct {
    identity: [32]u8,
    verifier: []u8,
    state: []u8,
    url: []u8,
    consumed: bool = false,
    pub fn deinit(self: *Browser, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.verifier);
        secret.zeroAndFree(alloc, self.state);
        alloc.free(self.url);
    }
};
pub const Status = struct {
    exists: bool = false,
    expired: bool = false,
    expires_at_ms: ?i64 = null,
    account: ?[]u8 = null,
    pub fn deinit(self: *Status, alloc: Allocator) void {
        if (self.account) |value| alloc.free(value);
    }
};
pub const Logout = struct { removed: bool = false, revocation_failed: bool = false };

fn check_cancel(cancel: *std.atomic.Value(bool)) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
}
fn random_secret(alloc: Allocator) ![]u8 {
    var entropy: [32]u8 = undefined;
    try io_mod.getIo().randomSecure(&entropy);
    const result = try alloc.alloc(u8, 43);
    _ = std.base64.url_safe_no_pad.Encoder.encode(result, &entropy);
    return result;
}
fn form(alloc: Allocator, fields: []const [2][]const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(alloc);
    defer writer.deinit();
    for (fields, 0..) |field, index| {
        if (index > 0) try writer.writer.writeByte('&');
        try encode(&writer.writer, field[0]);
        try writer.writer.writeByte('=');
        try encode(&writer.writer, field[1]);
    }
    return writer.toOwnedSlice();
}
fn encode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try writer.writeByte(c) else try writer.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] });
    }
}

test "generic OAuth browser challenge uses S256 and rejects state and cancellation before transport" {
    const alloc = std.testing.allocator;
    const adapter = Adapter{ .provider = .{ .id = "custom", .display_name = "Custom", .protocol = .openai_responses, .endpoint = "https://example.com", .auth = .{ .kind = .oauth_browser, .client_id = "public", .authorization_endpoint = "https://example.com/authorize", .token_endpoint = "https://example.com/token", .redirect_uri = "http://127.0.0.1:8900/callback", .scopes = &.{"inference"} } }, .transport = transport_mod.unavailable_provider };
    var cancel = std.atomic.Value(bool).init(false);
    var browser = try adapter.start_browser(alloc, &cancel);
    defer browser.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, browser.url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, browser.url, browser.verifier) == null);
    try std.testing.expectError(error.InvalidOAuthState, adapter.exchange_browser(alloc, &browser, "code", "wrong", &cancel));
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, adapter.exchange_browser(alloc, &browser, "code", browser.state, &cancel));
    try std.testing.expect(!browser.consumed);
}

const Mock = struct {
    response: []const u8 = "",
    rejected: bool = false,
    expected: []const u8 = "",
    calls: usize = 0,
    fn execute(raw: ?*anyopaque, alloc: Allocator, req: transport_mod.Request) !transport_mod.Response {
        const self: *Mock = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expect(std.mem.find(u8, req.payload.?, self.expected) != null);
        try std.testing.expect(req.deadline != null);
        return .{ .disposition = if (self.rejected) .rejected else .accepted, .body = try alloc.dupe(u8, self.response) };
    }
};

test "generic OAuth device refresh rotation status revocation and cancellation lifecycle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", home);
    const original = io_mod.environMap();
    io_mod.setEnvironMap(&env);
    defer if (original) |map| io_mod.setEnvironMap(map) else io_mod.setRawEnviron(&.{null});
    var mock = Mock{ .response = "{\"device_code\":\"device\",\"user_code\":\"ABCD\",\"verification_uri\":\"https://example.com/activate\",\"expires_in\":600,\"interval\":1}", .expected = "scope=inference%20offline_access" };
    const adapter = Adapter{ .provider = .{ .id = "custom", .display_name = "Custom", .protocol = .openai_responses, .endpoint = "https://example.com", .auth = .{ .kind = .oauth_device, .client_id = "public", .device_authorization_endpoint = "https://example.com/device", .token_endpoint = "https://example.com/token", .revocation_endpoint = "https://example.com/revoke", .scopes = &.{ "inference", "offline_access" } } }, .transport = .{ .context = &mock, .execute_fn = Mock.execute } };
    var cancel = std.atomic.Value(bool).init(false);
    var device = try adapter.start_device(alloc, &cancel);
    defer device.deinit(alloc);
    mock.expected = "device_code=device";
    mock.response = "{\"error\":\"slow_down\"}";
    mock.rejected = true;
    device.next_poll_ms = 0;
    try std.testing.expect((try adapter.poll_device(alloc, &device, &cancel)) == null);
    try std.testing.expectEqual(@as(i64, 6), device.authorization.interval);
    mock.rejected = false;
    mock.response = "{\"access_token\":\"first\",\"refresh_token\":\"refresh\",\"expires_in\":1,\"token_type\":\"Bearer\"}";
    device.next_poll_ms = 0;
    var token = (try adapter.poll_device(alloc, &device, &cancel)).?;
    token.deinit(alloc);
    var status_value = try adapter.status(alloc);
    defer status_value.deinit(alloc);
    try std.testing.expect(status_value.exists);
    mock.expected = "refresh_token=refresh";
    mock.response = "{\"access_token\":\"second\",\"expires_in\":3600,\"token_type\":\"Bearer\"}";
    const access = (try adapter.load_access(alloc, &cancel)).?;
    defer secret.zeroAndFree(alloc, access);
    try std.testing.expectEqualStrings("second", access);
    mock.expected = "token=refresh";
    mock.rejected = true;
    mock.response = "{\"error\":\"server_error\"}";
    const result = try adapter.logout(alloc, &cancel);
    try std.testing.expect(result.removed and result.revocation_failed);
    var absent = try adapter.status(alloc);
    defer absent.deinit(alloc);
    try std.testing.expect(!absent.exists);
    cancel.store(true, .release);
    const calls = mock.calls;
    try std.testing.expectError(error.Cancelled, adapter.start_device(alloc, &cancel));
    try std.testing.expectEqual(calls, mock.calls);
}
