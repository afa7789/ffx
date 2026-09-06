const std = @import("std");
const definition = @import("definition.zig");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    value: definition.OwnedDefinition,
    builtin: bool,
    order: usize,

    pub fn def(self: *const Entry) *const definition.Definition {
        return &self.value.parsed.value;
    }

    pub fn deinit(self: *Entry) void {
        self.value.deinit();
        self.* = undefined;
    }
};

/// Runtime provider registry. Definitions are owned by this registry for its
/// lifetime, so adapters may safely borrow their strings while a session is
/// active. Built-ins are inserted first; custom entries are sorted by id.
pub const Registry = struct {
    alloc: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.items.len;
    }

    pub fn entriesInOrder(self: *const Registry) []const Entry {
        return self.entries.items;
    }

    pub fn add(self: *Registry, owned: definition.OwnedDefinition, builtin: bool) !void {
        var candidate = owned;
        errdefer candidate.deinit();
        const id = candidate.parsed.value.id;
        if (self.lookup(id) != null) return error.DuplicateProviderId;
        for (self.entries.items) |*entry| {
            if (conflicts(&candidate.parsed.value, entry.def())) return error.DuplicateProviderAlias;
        }
        const order = self.entries.items.len;
        try self.entries.append(self.alloc, .{ .value = candidate, .builtin = builtin, .order = order });
        candidate = undefined;
    }

    /// Consumes owned on success and failure. Replaces an exact id, preserving
    /// native adapters and their credential identities across profile overrides.
    pub fn merge(self: *Registry, owned: definition.OwnedDefinition) !void {
        var candidate = owned;
        var consumed = false;
        errdefer if (!consumed) candidate.deinit();
        const incoming = &candidate.parsed.value;
        for (self.entries.items) |*entry| {
            const existing = entry.def();
            if (!std.mem.eql(u8, existing.id, incoming.id)) continue;
            if (entry.builtin and (existing.protocol == .native or existing.auth.kind == .oauth or existing.auth.kind == .oauth_native)) {
                if (existing.protocol != incoming.protocol or
                    !optional_equal(existing.adapter, incoming.adapter) or
                    !try self.auth_equal(existing.auth, incoming.auth) or
                    !optional_equal(existing.endpoint, incoming.endpoint)) return error.ImmutableNativeProvider;
            }
            for (self.entries.items) |*other| {
                if (other == entry) continue;
                if (conflicts(incoming, other.def())) return error.DuplicateProviderAlias;
            }
            entry.value.deinit();
            entry.value = candidate;
            return;
        }
        // add consumes even on failure; relinquish this scope's ownership first.
        const transferred = candidate;
        consumed = true;
        self.add(transferred, false) catch |err| return err;
    }

    fn auth_equal(self: *const Registry, a: definition.Auth, b: definition.Auth) !bool {
        var left = std.Io.Writer.Allocating.init(self.alloc);
        defer left.deinit();
        var right = std.Io.Writer.Allocating.init(self.alloc);
        defer right.deinit();
        try std.json.Stringify.value(a, .{}, &left.writer);
        try std.json.Stringify.value(b, .{}, &right.writer);
        return std.mem.eql(u8, left.written(), right.written());
    }

    fn optional_equal(a: ?[]const u8, b: ?[]const u8) bool {
        if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
        return b == null;
    }

    fn matches(value: *const definition.Definition, query: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(value.id, query) or std.ascii.eqlIgnoreCase(value.display_name, query)) return true;
        for (value.aliases) |alias| if (std.ascii.eqlIgnoreCase(alias, query)) return true;
        return false;
    }

    fn conflicts(a: *const definition.Definition, b: *const definition.Definition) bool {
        if (matches(b, a.id) or matches(b, a.display_name)) return true;
        for (a.aliases) |alias| if (matches(b, alias)) return true;
        return false;
    }

    pub fn addJson(self: *Registry, json: []const u8, builtin: bool) !void {
        try self.add(try definition.parse(self.alloc, json), builtin);
    }

    pub fn lookup(self: *const Registry, query: []const u8) ?*const Entry {
        var match: ?*const Entry = null;
        for (self.entries.items) |*entry| {
            const value = entry.def();
            if (std.ascii.eqlIgnoreCase(value.id, query) or
                std.ascii.eqlIgnoreCase(value.display_name, query))
            {
                if (match != null) return null;
                match = entry;
                continue;
            }
            for (value.aliases) |alias| {
                if (std.ascii.eqlIgnoreCase(alias, query)) {
                    if (match != null) return null;
                    match = entry;
                    break;
                }
            }
        }
        return match;
    }

    pub fn sortCustom(self: *Registry) void {
        const entries = self.entries.items;
        std.mem.sort(Entry, entries, {}, lessEntry);
        for (entries, 0..) |*entry, index| entry.order = index;
    }

    fn lessEntry(_: void, left: Entry, right: Entry) bool {
        if (left.builtin != right.builtin) return left.builtin;
        if (left.builtin and right.builtin) return left.order < right.order;
        return std.ascii.lessThanIgnoreCase(left.def().id, right.def().id);
    }
};

test "runtime registry resolves aliases and keeps builtins before sorted custom entries" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addJson("{\"id\":\"zeta\",\"display_name\":\"Zeta\",\"protocol\":\"openai_chat_completions\",\"endpoint\":\"https://z.example\",\"default_model\":\"z\",\"aliases\":[\"z\"]}", false);
    try registry.addJson("{\"id\":\"builtin\",\"display_name\":\"Builtin\",\"protocol\":\"openai_chat_completions\",\"endpoint\":\"https://b.example\",\"default_model\":\"b\"}", true);
    try registry.addJson("{\"id\":\"alpha\",\"display_name\":\"Alpha\",\"protocol\":\"anthropic_messages\",\"endpoint\":\"https://a.example\",\"default_model\":\"a\"}", false);
    registry.sortCustom();
    try std.testing.expectEqualStrings("builtin", registry.entriesInOrder()[0].def().id);
    try std.testing.expectEqualStrings("alpha", registry.entriesInOrder()[1].def().id);
    try std.testing.expectEqualStrings("zeta", registry.lookup("z").?.def().id);
}

test "runtime registry rejects duplicate ids and aliases" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addJson("{\"id\":\"one\",\"display_name\":\"One\",\"protocol\":\"openai_chat_completions\",\"endpoint\":\"https://one.example\",\"aliases\":[\"shared\"]}", true);
    try std.testing.expectError(error.DuplicateProviderId, registry.addJson("{\"id\":\"one\",\"display_name\":\"Other\",\"protocol\":\"openai_chat_completions\",\"endpoint\":\"https://two.example\"}", false));
    try std.testing.expectError(error.DuplicateProviderAlias, registry.addJson("{\"id\":\"two\",\"display_name\":\"Two\",\"protocol\":\"openai_chat_completions\",\"endpoint\":\"https://two.example\",\"aliases\":[\"shared\"]}", false));
}

test "runtime registry merges overrides and protects native identity" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addJson("{\"id\":\"native\",\"display_name\":\"Native\",\"protocol\":\"native\",\"adapter\":\"codex\",\"auth\":{\"kind\":\"oauth_native\",\"adapter\":\"codex\"}}", true);
    try std.testing.expectError(error.ImmutableNativeProvider, registry.merge(try definition.parse(std.testing.allocator, "{\"id\":\"native\",\"display_name\":\"Native\",\"protocol\":\"openai_responses\",\"endpoint\":\"https://other.test\"}")));
    try registry.merge(try definition.parse(std.testing.allocator, "{\"id\":\"custom\",\"display_name\":\"Custom\",\"protocol\":\"openai_responses\",\"endpoint\":\"https://first.test\"}"));
    try registry.merge(try definition.parse(std.testing.allocator, "{\"id\":\"custom\",\"display_name\":\"Custom\",\"protocol\":\"openai_responses\",\"endpoint\":\"https://second.test\"}"));
    try std.testing.expectEqualStrings("https://second.test", registry.lookup("custom").?.def().endpoint.?);
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectError(error.DuplicateProviderAlias, registry.merge(try definition.parse(std.testing.allocator, "{\"id\":\"other\",\"display_name\":\"Custom\",\"protocol\":\"openai_responses\",\"endpoint\":\"https://other.test\"}")));
}
