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
        for (candidate.parsed.value.aliases) |alias| {
            if (self.lookup(alias) != null) return error.DuplicateProviderAlias;
        }
        const order = self.entries.items.len;
        try self.entries.append(self.alloc, .{ .value = candidate, .builtin = builtin, .order = order });
        candidate = undefined;
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
