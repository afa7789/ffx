const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");

pub const Entry = struct {
    id: model_provider.ProviderId,
    slug: []const u8,
    aliases: []const []const u8 = &.{},
    name: []const u8,
    route_name: []const u8,
    description: []const u8,
    subscription: bool,
    login_source: types.CredentialSource,
};

pub const entries = [_]Entry{
    .{
        .id = .gateway,
        .slug = "vercel",
        .aliases = &.{ "gateway", "ai-gateway" },
        .name = "Vercel AI Gateway",
        .route_name = "Vercel AI Gateway",
        .description = "Vercel account or AI Gateway billing",
        .subscription = false,
        .login_source = .fx_login,
    },
    .{
        .id = .codex,
        .slug = "codex",
        .name = "Codex",
        .route_name = "Codex subscription",
        .description = "ChatGPT Plus, Pro, Business, Enterprise, or Edu subscription",
        .subscription = true,
        .login_source = .chatgpt_subscription,
    },
    .{
        .id = .grok,
        .slug = "grok",
        .name = "Grok",
        .route_name = "Grok subscription",
        .description = "SuperGrok or X Premium subscription",
        .subscription = true,
        .login_source = .grok_subscription,
    },
    .{ .id = .openai, .slug = "openai", .name = "OpenAI", .route_name = "OpenAI", .description = "OpenAI API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .anthropic, .slug = "anthropic", .name = "Anthropic", .route_name = "Anthropic", .description = "Anthropic API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .deepseek, .slug = "deepseek", .name = "DeepSeek", .route_name = "DeepSeek", .description = "DeepSeek API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .openrouter, .slug = "openrouter", .name = "OpenRouter", .route_name = "OpenRouter", .description = "OpenRouter API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .ppq, .slug = "ppq", .name = "PPQ", .route_name = "PPQ", .description = "PPQ API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .minimax, .slug = "minimax", .name = "MiniMax", .route_name = "MiniMax", .description = "MiniMax API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .zhipu, .slug = "zhipu", .name = "Zhipu (GLM)", .route_name = "Zhipu (GLM)", .description = "Zhipu API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .opencode_go, .slug = "opencode", .name = "OpenCode", .route_name = "OpenCode", .description = "OpenCode API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .zai, .slug = "zai", .aliases = &.{"z.ai"}, .name = "Z.AI", .route_name = "Z.AI", .description = "Z.AI API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .alibaba_cloud, .slug = "alibaba-cloud", .aliases = &.{"alibaba"}, .name = "Alibaba Cloud", .route_name = "Alibaba Cloud", .description = "Alibaba Cloud API key", .subscription = false, .login_source = .direct_provider },
    .{ .id = .custom, .slug = "custom", .name = "Custom provider", .route_name = "Custom provider", .description = "Configured custom provider", .subscription = false, .login_source = .direct_provider },
};

pub fn parse(value: []const u8) ?model_provider.ProviderId {
    for (&entries) |*entry| {
        if (std.ascii.eqlIgnoreCase(value, entry.slug)) return entry.id;
        for (entry.aliases) |alias| if (std.ascii.eqlIgnoreCase(value, alias)) return entry.id;
    }
    return null;
}

pub fn find(id: model_provider.ProviderId) *const Entry {
    for (&entries) |*entry| if (entry.id == id) return entry;
    unreachable;
}

pub fn label(id: model_provider.ProviderId) []const u8 {
    return find(id).route_name;
}

test "auth provider catalog uses the model provider identity and explicit aliases" {
    try std.testing.expectEqual(model_provider.ProviderId.gateway, parse("vercel").?);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(model_provider.ProviderId.codex, parse("codex").?);
    try std.testing.expectEqual(model_provider.ProviderId.grok, parse("grok").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("chatgpt") == null);
    try std.testing.expect(parse("unknown") == null);
    try std.testing.expect(find(.codex).subscription);
    try std.testing.expect(find(.grok).subscription);
    try std.testing.expectEqual(model_provider.ProviderId.openai, parse("openai").?);
    try std.testing.expectEqual(model_provider.ProviderId.opencode_go, parse("opencode").?);
    try std.testing.expectEqual(model_provider.ProviderId.zai, parse("z.ai").?);
    try std.testing.expectEqual(types.CredentialSource.direct_provider, find(.anthropic).login_source);
}
