const std = @import("std");

pub const Protocol = enum {
    openai_chat_completions,
    openai_responses,
    anthropic_messages,
    native,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Protocol {
        const value = try std.json.innerParse([]const u8, allocator, source, options);
        return parse_name(value);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Protocol {
        if (value != .string) return error.UnexpectedToken;
        return parse_name(value.string);
    }

    fn parse_name(value: []const u8) !Protocol {
        if (std.mem.eql(u8, value, "openai_compatible")) return .openai_chat_completions;
        return std.meta.stringToEnum(Protocol, value) orelse error.InvalidEnumTag;
    }
};

pub const Capabilities = struct {
    vision: bool = false,
    tools: bool = true,
    streaming: bool = true,
};

pub const AuthKind = enum { none, api_key, oauth, oauth_device, oauth_browser, oauth_authorization_code, oauth_native };

pub const Auth = struct {
    kind: AuthKind = .api_key,
    env_var: ?[]const u8 = null,
    header: ?[]const u8 = null,
    adapter: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    authorization_endpoint: ?[]const u8 = null,
    token_endpoint: ?[]const u8 = null,
    device_authorization_endpoint: ?[]const u8 = null,
    revocation_endpoint: ?[]const u8 = null,
    redirect_uri: ?[]const u8 = null,
    scopes: []const []const u8 = &.{},
};

/// Borrows all strings. Use parse or parse_value for allocator-owned data.
pub const Definition = struct {
    id: []const u8,
    display_name: []const u8,
    protocol: Protocol,
    adapter: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    models_endpoint: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    models: []const []const u8 = &.{},
    aliases: []const []const u8 = &.{},
    capabilities: Capabilities = .{},
    auth: Auth = .{},
    headers: std.json.ArrayHashMap([]const u8) = .{},
    timeout_ms: u32 = 60_000,

    pub fn validate(self: Definition) !void {
        try validate_id(self.id);
        try validate_text(self.display_name, 128);
        if (self.protocol == .native) {
            try validate_id(self.adapter orelse return error.MissingAdapter);
        } else {
            if (self.adapter != null) return error.UnexpectedAdapter;
            try validate_url(self.endpoint orelse return error.MissingEndpoint);
        }
        if (self.endpoint) |value| try validate_url(value);
        if (self.models_endpoint) |value| {
            try validate_text(value, 2048);
            if (!std.mem.startsWith(u8, value, "/") or std.mem.startsWith(u8, value, "//") or std.mem.findScalar(u8, value, '#') != null or std.mem.findScalar(u8, value, '?') != null or std.mem.findScalar(u8, value, '\\') != null) return error.InvalidModelsEndpoint;
        }
        if (self.default_model) |value| try validate_text(value, 1024);
        if (self.models.len > 4096 or self.aliases.len > 64) return error.TooManyEntries;
        for (self.models) |value| try validate_text(value, 1024);
        for (self.aliases) |value| try validate_text(value, 128);
        if (self.timeout_ms == 0 or self.timeout_ms > 600_000) return error.InvalidTimeout;
        if (self.auth.env_var) |value| {
            if (value.len == 0 or value.len > 128 or std.ascii.isDigit(value[0])) return error.InvalidEnvironmentVariable;
            for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidEnvironmentVariable;
        }
        if (self.auth.header) |value| {
            if (!std.ascii.eqlIgnoreCase(value, "authorization") and !std.ascii.eqlIgnoreCase(value, "x-api-key") and !std.ascii.eqlIgnoreCase(value, "api-key")) return error.InvalidAuthHeader;
        }
        var headers = self.headers.map.iterator();
        while (headers.next()) |entry| {
            const allowed = [_][]const u8{ "anthropic-version", "anthropic-beta", "openai-beta", "http-referer", "x-title", "accept" };
            var found = false;
            for (allowed) |name| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                found = true;
                break;
            };
            if (!found) return error.HeaderNotAllowed;
            try validate_text(entry.value_ptr.*, 1024);
        }
        switch (self.auth.kind) {
            .api_key, .none => {
                if (self.auth.adapter != null or self.auth.client_id != null or self.auth.authorization_endpoint != null or self.auth.token_endpoint != null or self.auth.device_authorization_endpoint != null or self.auth.revocation_endpoint != null or self.auth.redirect_uri != null or self.auth.scopes.len != 0) return error.UnexpectedOAuthConfiguration;
                if (self.auth.kind == .none and (self.auth.env_var != null or self.auth.header != null)) return error.UnexpectedCredentialConfiguration;
            },
            .oauth, .oauth_native => try validate_id(self.auth.adapter orelse return error.MissingOAuthAdapter),
            .oauth_device, .oauth_browser, .oauth_authorization_code => {
                try validate_text(self.auth.client_id orelse return error.MissingClientId, 512);
                try validate_url(self.auth.token_endpoint orelse return error.MissingTokenEndpoint);
                if (self.auth.kind == .oauth_device) {
                    try validate_url(self.auth.device_authorization_endpoint orelse return error.MissingDeviceEndpoint);
                } else {
                    try validate_url(self.auth.authorization_endpoint orelse return error.MissingAuthorizationEndpoint);
                    try validate_url(self.auth.redirect_uri orelse return error.MissingRedirectUri);
                }
            },
        }
        if (self.auth.adapter) |value| try validate_id(value);
        for ([_]?[]const u8{ self.auth.authorization_endpoint, self.auth.token_endpoint, self.auth.device_authorization_endpoint, self.auth.revocation_endpoint, self.auth.redirect_uri }) |optional| if (optional) |value| try validate_url(value);
        if (self.auth.scopes.len > 64) return error.TooManyEntries;
        for (self.auth.scopes) |value| try validate_text(value, 256);
    }
};

/// Owns every string and collection in parsed.value. Caller must deinit.
pub const OwnedDefinition = struct {
    parsed: std.json.Parsed(Definition),

    pub fn deinit(self: *OwnedDefinition) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn clone(self: OwnedDefinition, allocator: std.mem.Allocator) !OwnedDefinition {
        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        std.json.Stringify.value(self.parsed.value, .{}, &writer.writer) catch return error.OutOfMemory;
        return parse(allocator, writer.written());
    }
};

pub fn parse(allocator: std.mem.Allocator, json: []const u8) !OwnedDefinition {
    if (json.len > 2 * 1024 * 1024) return error.DefinitionTooLarge;
    const parsed = try std.json.parseFromSlice(Definition, allocator, json, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return .{ .parsed = parsed };
}

pub fn parse_value(allocator: std.mem.Allocator, value: std.json.Value) !OwnedDefinition {
    const parsed = try std.json.parseFromValue(Definition, allocator, value, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return .{ .parsed = parsed };
}

pub fn validate_id(value: []const u8) !void {
    if (value.len == 0 or value.len > 64 or !std.ascii.isAlphanumeric(value[0])) return error.InvalidProviderId;
    for (value) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_' or c == '.')) return error.InvalidProviderId;
}

fn validate_text(value: []const u8, max: usize) !void {
    if (value.len == 0 or value.len > max or std.mem.trim(u8, value, " \t\r\n").len != value.len or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    for (value) |c| if (c < 0x20 or c == 0x7f) return error.InvalidText;
}

pub fn validate_url(value: []const u8) !void {
    try validate_text(value, 2048);
    for (value) |c| if (c == ' ' or c == '\\') return error.InvalidEndpoint;
    const uri = std.Uri.parse(value) catch return error.InvalidEndpoint;
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidEndpoint;
    if (uri.host == null or uri.host.?.percent_encoded.len == 0 or uri.user != null or uri.password != null or uri.fragment != null or uri.query != null) return error.InvalidEndpoint;
}

test "provider definition owns strings and clones custom Anthropic models" {
    var value = try parse(std.testing.allocator,
        \\{"id":"private","display_name":"Private","protocol":"anthropic_messages","endpoint":"https://example.com/v1","models":["private-model"],"auth":{"kind":"api_key","header":"x-api-key"},"headers":{"anthropic-version":"2023-06-01"}}
    );
    var cloned = try value.clone(std.testing.allocator);
    defer cloned.deinit();
    value.deinit();
    try std.testing.expectEqualStrings("private-model", cloned.parsed.value.models[0]);
    try std.testing.expectEqual(Protocol.anthropic_messages, cloned.parsed.value.protocol);
}

test "provider definition rejects literal secrets and executable fields" {
    for ([_][]const u8{
        \\{"id":"custom","display_name":"Custom","protocol":"openai_responses","endpoint":"https://example.com","api_key":"secret"}
        ,
        \\{"id":"custom","display_name":"Custom","protocol":"openai_responses","endpoint":"https://example.com","auth":{"kind":"oauth","adapter":"custom","command":"run"}}
        ,
    }) |json| try std.testing.expectError(error.UnknownField, parse(std.testing.allocator, json));
}

test "provider endpoint rejects credentials invalid schemes and header injection" {
    for ([_][]const u8{ "https://user:secret@example.com", "javascript:alert(1)", "https://example.com\r\nx-api-key: secret", "https://example.com?key=secret", "https:///" }) |url| {
        if (validate_url(url)) |_| return error.TestUnexpectedResult else |_| {}
    }
    try validate_url("http://127.0.0.1:8080/v1");
}

test "standard OAuth definition requires endpoints and supports device configuration" {
    var value = try parse(std.testing.allocator,
        \\{"id":"device","display_name":"Device","protocol":"openai_compatible","endpoint":"https://example.com/v1","auth":{"kind":"oauth_device","client_id":"public-client","token_endpoint":"https://example.com/token","device_authorization_endpoint":"https://example.com/device","scopes":["inference"]}}
    );
    defer value.deinit();
    try std.testing.expectEqual(Protocol.openai_chat_completions, value.parsed.value.protocol);
    try std.testing.expectEqual(AuthKind.oauth_device, value.parsed.value.auth.kind);
}

test "provider value parser retains owned data after source lifetime" {
    var source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"id":"local","display_name":"Local","protocol":"openai_responses","endpoint":"http://localhost:3000","auth":{"kind":"none"}}
    , .{});
    var result = try parse_value(std.testing.allocator, source.value);
    defer result.deinit();
    source.deinit();
    try std.testing.expectEqualStrings("Local", result.parsed.value.display_name);
}

test "definition validates user supplied identifiers models and auth headers" {
    const base = Definition{ .id = "custom", .display_name = "Custom", .protocol = .openai_responses, .endpoint = "https://example.com" };
    var value = base;
    value.id = "../../other";
    try std.testing.expectError(error.InvalidProviderId, value.validate());
    value = base;
    value.models = &.{""};
    try std.testing.expectError(error.InvalidText, value.validate());
    value = base;
    value.auth.header = "Cookie";
    try std.testing.expectError(error.InvalidAuthHeader, value.validate());
    value = base;
    value.auth.env_var = "KEY=$(command)";
    try std.testing.expectError(error.InvalidEnvironmentVariable, value.validate());
    value = base;
    value.models_endpoint = "//other.example/models";
    try std.testing.expectError(error.InvalidModelsEndpoint, value.validate());
    value = base;
    value.auth.kind = .oauth;
    try std.testing.expectError(error.MissingOAuthAdapter, value.validate());
    value = base;
    value.auth.kind = .oauth_device;
    value.auth.client_id = "public";
    try std.testing.expectError(error.MissingTokenEndpoint, value.validate());
}

test "definition rejects secret headers" {
    try std.testing.expectError(error.HeaderNotAllowed, parse(std.testing.allocator,
        \\{"id":"custom","display_name":"Custom","protocol":"openai_responses","endpoint":"https://example.com","headers":{"Authorization":"Bearer secret"}}
    ));
}

fn allocation_failure_case(allocator: std.mem.Allocator) !void {
    var value = try parse(allocator,
        \\{"id":"custom","display_name":"Custom","protocol":"openai_responses","endpoint":"https://example.com","models":["private-model"],"aliases":["other"],"headers":{"x-title":"App"}}
    );
    defer value.deinit();
    var cloned = try value.clone(allocator);
    defer cloned.deinit();
}

test "definition parse and clone clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocation_failure_case, .{});
}
