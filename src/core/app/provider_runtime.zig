const std = @import("std");
const builtin = @import("builtin");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    active_provider: model_provider.ProviderId = .gateway,
    /// Stable textual id used by runtime-configured providers. Built-in enum
    /// remains as a compatibility projection for older call sites.
    active_provider_key: std.ArrayList(u8) = .empty,
    model: std.ArrayList(u8) = .empty,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.active_provider_key.deinit(self.alloc);
        self.model.deinit(self.alloc);
        self.* = undefined;
    }

    /// The returned model slice is borrowed until the next mutation or deinit.
    pub fn selection(self: *const Self) model_provider.ProviderSelection {
        return .{
            .provider = self.active_provider,
            .model = self.model.items,
        };
    }

    pub fn providerKey(self: *const Self) []const u8 {
        if (self.active_provider_key.items.len > 0) return self.active_provider_key.items;
        return model_provider.registryId(self.active_provider);
    }

    pub fn replaceModel(self: *Self, value: []const u8) !void {
        var owned = try self.alloc.dupe(u8, value);
        self.adoptOwned(self.active_provider, &owned);
    }

    pub fn replaceSelection(
        self: *Self,
        target_provider: model_provider.ProviderId,
        model_value: []const u8,
    ) !void {
        var owned = try self.alloc.dupe(u8, model_value);
        self.active_provider_key.clearRetainingCapacity();
        self.adoptOwned(target_provider, &owned);
    }

    /// Transfers `owned_model` into the runtime. All fallible preparation must
    /// finish before this no-fail publication boundary.
    pub fn adoptOwned(
        self: *Self,
        target_provider: model_provider.ProviderId,
        owned_model: *[]u8,
    ) void {
        self.model.deinit(self.alloc);
        self.model = .fromOwnedSlice(owned_model.*);
        owned_model.* = &.{};
        const keep_textual_key = self.active_provider == target_provider and self.active_provider_key.items.len > 0;
        self.active_provider = target_provider;
        if (!keep_textual_key) self.active_provider_key.clearRetainingCapacity();
    }

    /// Publishes a textual provider selection while preserving the legacy
    /// enum projection when the id names a built-in provider.
    pub fn adoptOwnedKey(
        self: *Self,
        target_key: []const u8,
        target_provider: model_provider.ProviderId,
        owned_model: *[]u8,
    ) !void {
        const owned_key = try self.alloc.dupe(u8, target_key);
        errdefer self.alloc.free(owned_key);
        self.adoptOwned(target_provider, owned_model);
        self.active_provider_key.deinit(self.alloc);
        self.active_provider_key = .fromOwnedSlice(owned_key);
    }
};

pub fn supported(comptime App: type) bool {
    return @hasField(App, "provider_selection") or
        (builtin.is_test and @hasField(App, "selected_model"));
}

pub fn model(app: anytype) []const u8 {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().model;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return app.selected_model.items;
    }
    @compileError("app must own provider_selection");
}

pub fn provider(app: anytype) model_provider.ProviderId {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_provider")) {
        return app.selected_provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return .gateway;
    }
    @compileError("app must own provider_selection");
}

pub fn providerKey(app: anytype) []const u8 {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) return app.provider_selection.providerKey();
    return model_provider.registryId(provider(app));
}

pub fn replaceModel(app: anytype, value: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceModel(value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        const stable = try app.alloc.dupe(u8, value);
        defer app.alloc.free(stable);
        try app.selected_model.ensureTotalCapacity(app.alloc, stable.len);
        app.selected_model.clearRetainingCapacity();
        app.selected_model.appendSliceAssumeCapacity(stable);
        return;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceSelection(
    app: anytype,
    selected_provider: model_provider.ProviderId,
    value: []const u8,
) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceSelection(selected_provider, value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        if (@hasField(App, "selected_provider")) app.selected_provider = selected_provider;
        return replaceModel(app, value);
    }
    @compileError("app must own provider_selection");
}

test "provider runtime adopts an owned selection without a fallible publication" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    var gateway_model = try alloc.dupe(u8, "gateway/model");
    runtime.adoptOwned(.gateway, &gateway_model);
    try std.testing.expectEqual(@as(usize, 0), gateway_model.len);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, runtime.selection().provider);
    try std.testing.expectEqualStrings("gateway/model", runtime.selection().model);

    var codex_model = try alloc.dupe(u8, "gpt-model");
    runtime.adoptOwned(.codex, &codex_model);
    try std.testing.expectEqual(@as(usize, 0), codex_model.len);
    try std.testing.expectEqual(model_provider.ProviderId.codex, runtime.selection().provider);
    try std.testing.expectEqualStrings("gpt-model", runtime.selection().model);
}

test "provider runtime preserves textual custom id while changing its model" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var owned_model = try std.testing.allocator.dupe(u8, "private-model");
    try runtime.adoptOwnedKey("my-provider", .gateway, &owned_model);
    try std.testing.expectEqualStrings("my-provider", runtime.providerKey());
    try runtime.replaceModel("another-model");
    try std.testing.expectEqualStrings("my-provider", runtime.providerKey());
    try std.testing.expectEqualStrings("another-model", runtime.selection().model);
}

test "provider runtime replaces custom identity sharing the legacy projection" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var first = try std.testing.allocator.dupe(u8, "first-model");
    try runtime.adoptOwnedKey("first", .gateway, &first);
    var second = try std.testing.allocator.dupe(u8, "second-model");
    try runtime.adoptOwnedKey("second", .gateway, &second);
    try std.testing.expectEqualStrings("second", runtime.providerKey());
    try std.testing.expectEqualStrings("second-model", runtime.selection().model);
}
