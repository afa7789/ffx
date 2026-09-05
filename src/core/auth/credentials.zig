const std = @import("std");
const builtin = @import("builtin");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const types = @import("../shared/types.zig");

pub const Source = types.CredentialSource;

pub const CatalogPublicOnly = union(enum) {
    no_credential,
    authenticated_credential_rejected: Source,

    fn credentialSource(self: CatalogPublicOnly) ?Source {
        return switch (self) {
            .no_credential => null,
            .authenticated_credential_rejected => |source| source,
        };
    }
};

pub const CatalogPublicOnlyReason = std.meta.Tag(CatalogPublicOnly);

pub const CatalogAuthenticatedSource = enum {
    env_var,
    stored_key,

    fn credentialSource(self: CatalogAuthenticatedSource) Source {
        return switch (self) {
            .env_var => .env_var,
            .stored_key => .stored_key,
        };
    }
};

/// A borrowed authorization decision for one model-catalog request. Public-only
/// states cannot carry credential or team bytes; authenticated states carry the
/// only values the request is allowed to send.
pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnly,
    authenticated: struct {
        source: CatalogAuthenticatedSource,
        credential: []const u8,
        team_context: ?[]const u8,
        account_id: ?[]const u8 = null,
    },

    pub fn credentialSource(self: CatalogAccess) ?Source {
        return switch (self) {
            .public_only => |access| access.credentialSource(),
            .authenticated => |access| access.source.credentialSource(),
        };
    }

    pub fn publicOnlyReason(self: CatalogAccess) ?CatalogPublicOnlyReason {
        const access = self.publicOnly() orelse return null;
        return std.meta.activeTag(access);
    }

    pub fn publicOnly(self: CatalogAccess) ?CatalogPublicOnly {
        return switch (self) {
            .public_only => |access| access,
            .authenticated => null,
        };
    }

    pub fn publicFallbackAfterRejection(self: CatalogAccess) ?CatalogAccess {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| .{
                .public_only = .{
                    .authenticated_credential_rejected = access.source.credentialSource(),
                },
            },
        };
    }

    pub fn authorizationCredential(self: CatalogAccess) ?[]const u8 {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| access.credential,
        };
    }

    pub fn teamContext(self: CatalogAccess) ?[]const u8 {
        const team = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.team_context orelse return null,
        };
        return if (team.len > 0) team else null;
    }

    pub fn accountId(self: CatalogAccess) ?[]const u8 {
        const account_id = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.account_id orelse return null,
        };
        return if (account_id.len > 0) account_id else null;
    }
};

pub fn catalogAccessAt(credential: ?Credential) CatalogAccess {
    const selected = credential orelse return .{ .public_only = .no_credential };
    return catalogAccessForCredentialAndAccount(
        selected.source,
        selected.token,
        selected.gatewayTeam(),
        selected.accountId(),
    );
}

pub fn catalogAccessForCredential(
    source: ?Source,
    credential: []const u8,
    team_context: ?[]const u8,
) CatalogAccess {
    return catalogAccessForCredentialAndAccount(source, credential, team_context, null);
}

pub fn catalogAccessForCredentialAndAccount(
    source: ?Source,
    credential: []const u8,
    team_context: ?[]const u8,
    account_id: ?[]const u8,
) CatalogAccess {
    const selected_source = source orelse return .{ .public_only = .no_credential };
    const authenticated_source: CatalogAuthenticatedSource = switch (selected_source) {
        .env_var => .env_var,
        .stored_key => .stored_key,
    };
    return .{
        .authenticated = .{
            .source = authenticated_source,
            .credential = credential,
            .team_context = team_context,
            .account_id = account_id,
        },
    };
}

/// Current native product copy. Store mechanics and availability come from the
/// injected host port; Core retains the stable user-facing source name.
pub const stored_key_backend_label = if (builtin.os.tag == .macos) "macOS Keychain" else "profile file";

pub const missing_credential_message = "Fx needs access to a model provider. Run ffx login, or ffx setup to use an API key, or set FFX_PROVIDER_API_KEY + FFX_PROVIDER_BASE_URL, or set AI_GATEWAY_API_KEY.";
pub const missing_interactive_credential_message = "Fx needs access to a model provider. Open /setup, or set FFX_PROVIDER_API_KEY + FFX_PROVIDER_BASE_URL.";
pub const missing_chatgpt_credential_message = "ffx needs a Codex subscription login for this model. Run ffx login codex.";
pub const missing_chatgpt_interactive_credential_message = "Codex needs a subscription login. Open /setup and choose Sign in with Codex.";
pub const missing_grok_credential_message = "ffx needs a Grok subscription login for this model. Run ffx login grok.";
pub const missing_grok_interactive_credential_message = "Grok needs a subscription login. Open /setup and choose Sign in with Grok.";
pub const unreadable_store_message = "Fx could not read the stored API key from " ++ stored_key_backend_label ++ ". A key may be saved but unreadable. Set FFX_TRACE_LOG for the failing step, or set FFX_PROVIDER_API_KEY.";

pub const Credential = struct {
    token: []u8,
    source: Source,
    account_id: ?[]u8 = null,
    team_id: ?[]u8 = null,
    team_slug: ?[]u8 = null,

    pub fn deinit(self: *Credential, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        if (self.account_id) |account_id| alloc.free(account_id);
        if (self.team_id) |team| alloc.free(team);
        if (self.team_slug) |team| alloc.free(team);
        self.* = undefined;
    }

    pub fn gatewayTeam(self: Credential) ?[]const u8 {
        if (self.team_id) |team| return team;
        return self.team_slug;
    }

    pub fn accountId(self: Credential) ?[]const u8 {
        return self.account_id;
    }
};

pub const StoredKeyReadStatus = enum {
    not_attempted,
    not_found,
    unavailable,
};

pub const Resolution = struct {
    credential: ?Credential = null,
    stored_key_status: StoredKeyReadStatus = .not_attempted,
};

/// Simple credential resolution: try the active provider's stored key first
/// (per-provider Keychain entry, then the settings.json api_keys map), then
/// the legacy stored key, then the env var. Returns the first credential
/// found, or null.
pub fn resolve(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
) !Resolution {
    return resolveForProvider(alloc, secret_store, null);
}

/// Same as `resolve`, but `provider_hint` overrides the active provider read
/// from settings.json. Pass `@tagName(provider)` where the caller already
/// knows which provider is being authorized.
pub fn resolveForProvider(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    provider_hint: ?[]const u8,
) !Resolution {
    var settings = readStoredSettings(alloc, provider_hint);
    defer settings.deinit(alloc);
    const active_provider = provider_hint orelse settings.provider;

    // 1. Active-provider stored key: per-provider Keychain entry first, then
    // the settings.json api_keys map (a plain file, so it is consulted even
    // when the keychain is disabled).
    if (active_provider) |provider| {
        if (loadProviderStoredKey(alloc, secret_store, provider, settings.api_key)) |credential| {
            return .{ .credential = credential };
        }
    }

    // 2. Legacy stored key (AI Gateway Keychain service).
    if (!secret_store.isDisabled()) {
        var status: StoredKeyReadStatus = .not_found;
        const stored = loadSource(alloc, secret_store, .stored_key) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            status = .unavailable;
            debug_trace.logf("auth", "stored key load failed err={s} status={t}", .{ @errorName(err), status });
            break :blk null;
        };
        if (stored) |credential| return .{ .credential = credential };

        // 3. Fall back to the environment variable, remembering what the
        // store reported so callers can distinguish absent from unreadable.
        if (try loadSource(alloc, secret_store, .env_var)) |credential| {
            return .{ .credential = credential };
        }
        return .{ .stored_key_status = status };
    }

    // 4. Store disabled: environment variable only.
    if (try loadSource(alloc, secret_store, .env_var)) |credential| return .{ .credential = credential };

    return .{};
}

/// Resolves only the credential owned by one direct provider. Unlike the
/// legacy resolver, this never falls back to an AI Gateway key or the generic
/// provider key, so connection discovery cannot report false matches.
pub fn resolveDirectProvider(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    provider: []const u8,
    env_var: []const u8,
) !?Credential {
    if (try loadEnvCredential(alloc, env_var, .env_var)) |credential| return credential;
    var settings = readStoredSettings(alloc, provider);
    defer settings.deinit(alloc);
    if (loadProviderStoredKey(alloc, secret_store, provider, settings.api_key)) |credential| {
        return credential;
    }
    if (std.mem.eql(u8, provider, "opencode")) {
        var legacy = readStoredSettings(alloc, "opencode-go");
        defer legacy.deinit(alloc);
        if (loadProviderStoredKey(alloc, secret_store, "opencode-go", legacy.api_key)) |credential| {
            return credential;
        }
    }
    return null;
}

pub fn directProviderExists(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    provider: []const u8,
    env_var: []const u8,
) !bool {
    var credential = (try resolveDirectProvider(alloc, secret_store, provider, env_var)) orelse return false;
    credential.deinit(alloc);
    return true;
}

/// Stores one provider key in Keychain when available, with the profile
/// `api_keys` map as the portable fallback.
pub fn storeDirectProviderKey(alloc: std.mem.Allocator, provider: []const u8, key: []const u8) !void {
    if (native_keychain.isAvailable() and !native_keychain.isDisabled()) {
        native_keychain.saveApiKey(alloc, provider, key) catch |err| switch (err) {
            error.UnsupportedPlatform => {},
            else => return err,
        };
        return;
    }

    var api_keys: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer api_keys.deinit(alloc);
    try api_keys.put(alloc, provider, key);
    var outcome = try config_runtime.setUserPreferences(alloc, .{ .api_keys = api_keys });
    outcome.deinit(alloc);
}

pub fn loadSource(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
) !?Credential {
    return switch (source) {
        .env_var => loadEnvCredential(alloc, "FFX_PROVIDER_API_KEY", source),
        .stored_key => loadStoredKeyCredential(alloc, secret_store),
    };
}

pub fn sourceExists(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
) !bool {
    return sourceExistsForProvider(alloc, secret_store, source, null);
}

pub fn sourceExistsForProvider(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
    provider_hint: ?[]const u8,
) !bool {
    return switch (source) {
        .env_var => nonEmptyEnvValue("FFX_PROVIDER_API_KEY") != null,
        .stored_key => blk: {
            var settings = readStoredSettings(alloc, provider_hint);
            defer settings.deinit(alloc);
            if (provider_hint orelse settings.provider) |active| {
                if (settings.api_key != null) break :blk true;
                if (!secret_store.isDisabled() and !native_keychain.isDisabled()) {
                    if (native_keychain.loadApiKey(alloc, active)) |key| {
                        alloc.free(key);
                        break :blk true;
                    }
                }
            }
            if (secret_store.isDisabled()) break :blk false;
            const stored = secret_store.load(alloc) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("auth", "source probe failed source=stored_key err={s}", .{@errorName(err)});
                    break :blk false;
                },
            };
            const value = stored orelse break :blk false;
            secret.zeroAndFree(alloc, value);
            break :blk true;
        },
    };
}

const max_settings_probe_bytes: usize = 64 * 1024;

/// The active provider id and its saved key from ~/.ffx/settings.json. Both
/// fields are owned by the struct and freed by `deinit`.
pub const StoredSettings = struct {
    provider: ?[]u8 = null,
    api_key: ?[]u8 = null,

    pub fn deinit(self: *StoredSettings, alloc: std.mem.Allocator) void {
        if (self.provider) |provider| alloc.free(provider);
        if (self.api_key) |api_key| alloc.free(api_key);
        self.* = undefined;
    }
};

/// Standalone bounded reader for ~/.ffx/settings.json that extracts only the
/// "provider" field and the api_keys entry for `provider_hint` (or the stored
/// provider when no hint is given). Fields are null when HOME is unset or the
/// file is absent, unreadable, oversized, or not a JSON object.
fn readStoredSettings(alloc: std.mem.Allocator, provider_hint: ?[]const u8) StoredSettings {
    const zio = io_mod.getIo();
    const home = io_mod.getenv("HOME") orelse return .{};
    const path = profile_paths.settingsPath(alloc, home) catch return .{};
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return .{};
    defer file.close(zio);
    const stat = file.stat(zio) catch return .{};
    if (stat.kind != .file or stat.size > max_settings_probe_bytes) return .{};

    const bytes = io_mod.readFileToEnd(alloc, &file, max_settings_probe_bytes + 1) catch return .{};
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    const provider = dupeStringField(alloc, parsed.value.object.get("provider"));
    const api_key: ?[]u8 = blk: {
        const map = parsed.value.object.get("api_keys") orelse break :blk null;
        if (map != .object) break :blk null;
        const active = provider_hint orelse (provider orelse break :blk null);
        break :blk dupeStringField(alloc, map.object.get(active));
    };
    return .{ .provider = provider, .api_key = api_key };
}

fn dupeStringField(alloc: std.mem.Allocator, value: ?std.json.Value) ?[]u8 {
    const field = value orelse return null;
    if (field != .string or field.string.len == 0) return null;
    return alloc.dupe(u8, field.string) catch null;
}

/// Loads the stored credential for one provider: its per-provider Keychain
/// entry first, then the settings.json api_keys fallback.
fn loadProviderStoredKey(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    provider: []const u8,
    settings_api_key: ?[]const u8,
) ?Credential {
    if (!secret_store.isDisabled() and !native_keychain.isDisabled()) {
        if (native_keychain.loadApiKey(alloc, provider)) |key| {
            return .{ .token = @constCast(key), .source = .stored_key };
        }
    }
    const settings_key = settings_api_key orelse return null;
    const token = alloc.dupe(u8, settings_key) catch return null;
    return .{ .token = token, .source = .stored_key };
}

fn loadEnvCredential(
    alloc: std.mem.Allocator,
    name: []const u8,
    source: Source,
) !?Credential {
    const value = nonEmptyEnvValue(name) orelse return null;
    return .{
        .token = try alloc.dupe(u8, value),
        .source = source,
    };
}

fn loadStoredKeyCredential(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
) !?Credential {
    if (secret_store.isDisabled()) return null;
    const value = (try secret_store.load(alloc)) orelse return null;
    return .{ .token = value, .source = .stored_key };
}

fn nonEmptyEnvValue(name: []const u8) ?[]const u8 {
    return nonEmptyValue(io_mod.getenv(name));
}

fn nonEmptyValue(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .env_var => "Environment variable",
        .stored_key => "Stored key (" ++ stored_key_backend_label ++ ")",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stored key label discloses the backend that answered" {
    try std.testing.expect(std.mem.find(u8, sourceLabel(.stored_key), stored_key_backend_label) != null);
    try std.testing.expect(std.mem.find(u8, unreadable_store_message, stored_key_backend_label) != null);
    try std.testing.expect(!std.mem.eql(u8, sourceLabel(.env_var), sourceLabel(.stored_key)));
}

test "missing credential messages use surface commands in preferred order" {
    const cli_login = std.mem.find(u8, missing_credential_message, "ffx login").?;
    const cli_setup = std.mem.find(u8, missing_credential_message, "ffx setup").?;
    const cli_env = std.mem.find(u8, missing_credential_message, "AI_GATEWAY_API_KEY").?;
    try std.testing.expect(cli_login < cli_setup);
    try std.testing.expect(cli_setup < cli_env);

    const tui_setup = std.mem.find(u8, missing_interactive_credential_message, "/setup").?;
    const tui_direct = std.mem.find(u8, missing_interactive_credential_message, "FFX_PROVIDER_API_KEY").?;
    try std.testing.expect(tui_setup < tui_direct);
    try std.testing.expect(std.mem.find(u8, missing_interactive_credential_message, "/login") == null);
}

test "catalog access isolates public and authenticated provider credentials" {
    const missing = catalogAccessAt(null);
    try std.testing.expectEqual(CatalogPublicOnlyReason.no_credential, missing.publicOnlyReason().?);
    try std.testing.expect(missing.credentialSource() == null);
    try std.testing.expect(missing.authorizationCredential() == null);
    try std.testing.expect(missing.teamContext() == null);

    const env_credential = catalogAccessForCredential(
        .env_var,
        "env-secret",
        "team-context",
    );
    try std.testing.expectEqual(Source.env_var, env_credential.credentialSource().?);
    try std.testing.expectEqualStrings("env-secret", env_credential.authorizationCredential().?);
    try std.testing.expect(env_credential.teamContext() != null);
    try std.testing.expect(env_credential.publicFallbackAfterRejection() != null);

    var stored_credential = Credential{
        .token = try std.testing.allocator.dupe(u8, "stored-secret"),
        .source = .stored_key,
        .account_id = try std.testing.allocator.dupe(u8, "acct_stored"),
    };
    defer stored_credential.deinit(std.testing.allocator);
    const stored = catalogAccessAt(stored_credential);
    try std.testing.expectEqualStrings("acct_stored", stored.accountId().?);

    const rejected: CatalogAccess = .{ .public_only = .{ .authenticated_credential_rejected = .stored_key } };
    try std.testing.expectEqual(CatalogPublicOnlyReason.authenticated_credential_rejected, rejected.publicOnlyReason().?);
    try std.testing.expectEqual(Source.stored_key, rejected.credentialSource().?);
    try std.testing.expect(rejected.authorizationCredential() == null);
    try std.testing.expect(rejected.teamContext() == null);
}

test "authenticated catalog access carries source and permitted request context" {
    for ([_]Source{ .env_var, .stored_key }) |source| {
        var credential = Credential{
            .token = try std.testing.allocator.dupe(u8, "token"),
            .source = source,
            .team_slug = try std.testing.allocator.dupe(u8, "vercel-labs"),
        };
        defer credential.deinit(std.testing.allocator);

        const authenticated = catalogAccessAt(credential);
        try std.testing.expect(authenticated.publicOnlyReason() == null);
        try std.testing.expectEqual(source, authenticated.credentialSource().?);
        try std.testing.expectEqualStrings("token", authenticated.authorizationCredential().?);
        try std.testing.expectEqualStrings("vercel-labs", authenticated.teamContext().?);

        const fallback = authenticated.publicFallbackAfterRejection().?;
        try std.testing.expectEqual(CatalogPublicOnlyReason.authenticated_credential_rejected, fallback.publicOnlyReason().?);
        try std.testing.expectEqual(source, fallback.credentialSource().?);
        try std.testing.expect(fallback.authorizationCredential() == null);
        try std.testing.expect(fallback.teamContext() == null);
        try std.testing.expect(fallback.publicFallbackAfterRejection() == null);
    }
}

var stable_credential_test_environ: ?*std.process.Environ.Map = null;

fn stableCredentialTestEnviron() !*const std.process.Environ.Map {
    if (stable_credential_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_credential_test_environ = map;
    return map;
}

const CredentialTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: std.mem.Allocator, entries: []const [2][]const u8) !*CredentialTestEnv {
        _ = try stableCredentialTestEnviron();

        const self = try alloc.create(CredentialTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        for (entries) |entry| try self.map.put(entry[0], entry[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *CredentialTestEnv) void {
        if (stable_credential_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const SecretStoreFixture = struct {
    value: ?[]const u8 = null,
    disabled: bool = false,
    unreadable: bool = false,
    load_calls: usize = 0,

    fn provider(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = isDisabled,
            .load_fn = load,
            .store_fn = store,
            .store_interactive_fn = storeInteractive,
        };
    }

    fn isDisabled(raw_context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        return self.disabled;
    }

    fn load(
        raw_context: ?*anyopaque,
        alloc: std.mem.Allocator,
    ) host.SecretStoreLoadError!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        self.load_calls += 1;
        if (self.unreadable) return error.StoredKeyUnreadable;
        const value = self.value orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn store(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
    ) host.SecretStoreWriteError!void {
        return error.StoredKeyWriteFailed;
    }

    fn storeInteractive(
        _: ?*anyopaque,
    ) host.SecretStoreWriteError!bool {
        return false;
    }
};

test "source-specific credential loading" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "FFX_PROVIDER_API_KEY", "api-key" },
    });
    defer env.deinit();

    var api_key = (try loadSource(alloc, host.unavailable_secret_store, .env_var)).?;
    defer api_key.deinit(alloc);
    try std.testing.expectEqualStrings("api-key", api_key.token);
    try std.testing.expectEqual(Source.env_var, api_key.source);

    try std.testing.expect(try sourceExists(alloc, host.unavailable_secret_store, .env_var));
    try std.testing.expect(!(try sourceExists(alloc, host.unavailable_secret_store, .stored_key)));
}

test "direct provider environment credential takes precedence without reading stores" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "CUSTOM_PROVIDER_KEY", "custom-env-key" },
        .{ "FFX_PROVIDER_API_KEY", "foreign-key" },
    });
    defer env.deinit();
    var fixture = SecretStoreFixture{ .value = "stored-key" };
    var credential = (try resolveDirectProvider(alloc, fixture.provider(), "custom", "CUSTOM_PROVIDER_KEY")).?;
    defer credential.deinit(alloc);
    try std.testing.expectEqualStrings("custom-env-key", credential.token);
    try std.testing.expectEqual(Source.env_var, credential.source);
    try std.testing.expectEqual(@as(usize, 0), fixture.load_calls);
}

test "a disabled stored key is reported as never attempted, not as absent" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{});
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .disabled = true };

    var resolution = try resolve(alloc, store_fixture.provider());
    defer if (resolution.credential) |*credential| credential.deinit(alloc);
    try std.testing.expect(resolution.credential == null);
    try std.testing.expectEqual(StoredKeyReadStatus.not_attempted, resolution.stored_key_status);
    try std.testing.expectEqual(@as(usize, 0), store_fixture.load_calls);
}

test "credential resolution loads a stored key only through the injected host port" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{});
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .value = "injected-test-value" };

    var resolution = try resolve(alloc, store_fixture.provider());
    defer if (resolution.credential) |*credential| credential.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), store_fixture.load_calls);
    try std.testing.expectEqual(StoredKeyReadStatus.not_attempted, resolution.stored_key_status);
    try std.testing.expectEqual(Source.stored_key, resolution.credential.?.source);
    try std.testing.expectEqualStrings("injected-test-value", resolution.credential.?.token);
}

test "credential resolution preserves unreadable store classification" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{});
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .unreadable = true };

    const resolution = try resolve(alloc, store_fixture.provider());

    try std.testing.expectEqual(@as(usize, 1), store_fixture.load_calls);
    try std.testing.expect(resolution.credential == null);
    try std.testing.expectEqual(StoredKeyReadStatus.unavailable, resolution.stored_key_status);
}

test "env var credential wins when stored key is disabled" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "FFX_PROVIDER_API_KEY", "env-key" },
    });
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .disabled = true };

    var resolution = try resolve(alloc, store_fixture.provider());
    defer if (resolution.credential) |*credential| credential.deinit(alloc);

    const credential = resolution.credential orelse return error.TestExpectedCredential;
    try std.testing.expectEqual(Source.env_var, credential.source);
    try std.testing.expectEqualStrings("env-key", credential.token);
}

test "stored key wins over env var when both are available" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "FFX_PROVIDER_API_KEY", "env-key" },
    });
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .value = "stored-key-value" };

    var resolution = try resolve(alloc, store_fixture.provider());
    defer if (resolution.credential) |*credential| credential.deinit(alloc);

    const credential = resolution.credential orelse return error.TestExpectedCredential;
    try std.testing.expectEqual(Source.stored_key, credential.source);
    try std.testing.expectEqualStrings("stored-key-value", credential.token);
}

fn installSettingsFixture(tmp: *std.testing.TmpDir, contents: []const u8) ![]u8 {
    const alloc = std.testing.allocator;
    try tmp.dir.createDirPath(io_mod.getIo(), profile_paths.root_dir_name);
    var file = try tmp.dir.createFile(
        io_mod.getIo(),
        profile_paths.root_dir_name ++ "/settings.json",
        .{ .truncate = true },
    );
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), contents);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

test "settings.json api_keys resolves the active provider stored key" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try installSettingsFixture(
        &tmp,
        "{\"provider\":\"deepseek\",\"api_keys\":{\"deepseek\":\"sk-test-123\"}}",
    );
    defer alloc.free(home);

    const env = try CredentialTestEnv.install(alloc, &.{.{ "HOME", home }});
    defer env.deinit();
    // Keychain fully disabled: the settings.json file fallback still applies.
    var store_fixture = SecretStoreFixture{ .disabled = true };

    var resolution = try resolveForProvider(alloc, store_fixture.provider(), null);
    defer if (resolution.credential) |*credential| credential.deinit(alloc);
    const credential = resolution.credential orelse return error.TestExpectedCredential;
    try std.testing.expectEqual(Source.stored_key, credential.source);
    try std.testing.expectEqualStrings("sk-test-123", credential.token);

    // An explicit provider hint overrides the settings.json provider.
    var hinted = try resolveForProvider(alloc, store_fixture.provider(), "openai");
    defer if (hinted.credential) |*hint_credential| hint_credential.deinit(alloc);
    try std.testing.expect(hinted.credential == null);

    // The TUI picker's source probe sees the same stored key.
    try std.testing.expect(try sourceExists(alloc, store_fixture.provider(), .stored_key));
}

test "settings api key wins over env var when both are available" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try installSettingsFixture(
        &tmp,
        "{\"provider\":\"deepseek\",\"api_keys\":{\"deepseek\":\"sk-stored\"}}",
    );
    defer alloc.free(home);

    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "HOME", home },
        .{ "FFX_PROVIDER_API_KEY", "env-key" },
    });
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .disabled = true };

    var resolution = try resolveForProvider(alloc, store_fixture.provider(), null);
    defer if (resolution.credential) |*credential| credential.deinit(alloc);

    const credential = resolution.credential orelse return error.TestExpectedCredential;
    try std.testing.expectEqual(Source.stored_key, credential.source);
    try std.testing.expectEqualStrings("sk-stored", credential.token);
}
