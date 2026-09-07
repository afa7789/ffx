const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    gateway,
    codex,
    grok,
    minimax,
    openrouter,
    ppq,
    zhipu,
    deepseek,
    anthropic,
    openai,
    opencode_go,
    zai,
    alibaba_cloud,
    custom,
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    if (std.ascii.eqlIgnoreCase(value, "minimax")) return .minimax;
    if (std.ascii.eqlIgnoreCase(value, "openrouter")) return .openrouter;
    if (std.ascii.eqlIgnoreCase(value, "ppq")) return .ppq;
    if (std.ascii.eqlIgnoreCase(value, "zhipu")) return .zhipu;
    if (std.ascii.eqlIgnoreCase(value, "deepseek")) return .deepseek;
    if (std.ascii.eqlIgnoreCase(value, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(value, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(value, "opencode") or std.ascii.eqlIgnoreCase(value, "opencode-go")) return .opencode_go;
    if (std.ascii.eqlIgnoreCase(value, "zai") or std.ascii.eqlIgnoreCase(value, "z.ai")) return .zai;
    if (std.ascii.eqlIgnoreCase(value, "alibaba-cloud") or std.ascii.eqlIgnoreCase(value, "alibaba")) return .alibaba_cloud;
    if (std.ascii.eqlIgnoreCase(value, "custom")) return .custom;
    return null;
}

pub fn label(provider: ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "AI Gateway",
        .codex => "Codex subscription",
        .grok => "Grok subscription",
        .minimax => "Minimax",
        .openrouter => "OpenRouter",
        .ppq => "PPQ",
        .zhipu => "Zhipu (GLM)",
        .deepseek => "DeepSeek",
        .anthropic => "Anthropic",
        .openai => "OpenAI",
        .opencode_go => "OpenCode",
        .zai => "Z.AI",
        .alibaba_cloud => "Alibaba Cloud",
        .custom => "Custom provider",
    };
}

/// Registry id used in `~/.ffx/settings.json`, keychain service names, and
/// `builtins/providers.zig`. Matches `@tagName` except for ids that need a
/// hyphen (enum tags cannot carry one).
pub fn registryId(provider: ProviderId) []const u8 {
    return switch (provider) {
        .opencode_go => "opencode",
        .alibaba_cloud => "alibaba-cloud",
        else => @tagName(provider),
    };
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    if (selected == .host_managed) return true;
    return switch (provider) {
        .gateway => selected != .chatgpt_subscription and selected != .grok_subscription and selected != .direct_provider,
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
        else => selected == .direct_provider,
    };
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
}

test "provider parsing exposes gateway codex and grok" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("") == null);
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return provider == .gateway;
}
