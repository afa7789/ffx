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
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
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
    // "gateway" is a legacy sentinel; not exposed in the picker.
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    return null;
}

pub fn label(provider: ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "Gateway (legacy)",
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
    return switch (provider) {
        .gateway => selected == .env_var or selected == .stored_key,
        .codex, .grok => selected == .stored_key,
        .minimax, .openrouter, .ppq, .zhipu, .deepseek, .anthropic, .openai, .opencode_go, .zai, .alibaba_cloud => selected == .env_var or selected == .stored_key,
    };
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    // Only the legacy `.gateway` sentinel carries gateway auxiliaries (Vision
    // fallback etc.). Direct providers own their features upstream.
    return provider == .gateway;
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.codex, .stored_key));
    try std.testing.expect(!authorizesCredential(.codex, .env_var));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .stored_key));
    try std.testing.expect(!authorizesCredential(.grok, .env_var));
}

test "direct API key providers authorize env_var and stored_key" {
    const direct_providers = [_]ProviderId{ .minimax, .openrouter, .ppq, .zhipu, .deepseek, .anthropic, .openai, .opencode_go, .zai, .alibaba_cloud };
    for (direct_providers) |provider| {
        try std.testing.expect(authorizesCredential(provider, .env_var));
        try std.testing.expect(authorizesCredential(provider, .stored_key));
        try std.testing.expect(!authorizesCredential(provider, null));
    }
}

test "provider parsing exposes all variants" {
    try std.testing.expectEqual(ProviderId.codex, parse("codex").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expectEqual(ProviderId.minimax, parse("minimax").?);
    try std.testing.expectEqual(ProviderId.openrouter, parse("OpenRouter").?);
    try std.testing.expectEqual(ProviderId.ppq, parse("PPQ").?);
    try std.testing.expectEqual(ProviderId.zhipu, parse("zhipu").?);
    try std.testing.expectEqual(ProviderId.deepseek, parse("DEEPSEEK").?);
    try std.testing.expectEqual(ProviderId.anthropic, parse("anthropic").?);
    try std.testing.expectEqual(ProviderId.openai, parse("OpenAI").?);
    try std.testing.expectEqual(ProviderId.opencode_go, parse("opencode").?);
    try std.testing.expectEqual(ProviderId.zai, parse("Z.AI").?);
    try std.testing.expectEqual(ProviderId.alibaba_cloud, parse("alibaba").?);
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("unknown") == null);
}

test "only the gateway sentinel uses gateway auxiliaries" {
    const direct_providers = [_]ProviderId{ .codex, .grok, .minimax, .openrouter, .ppq, .zhipu, .deepseek, .anthropic, .openai, .opencode_go, .zai, .alibaba_cloud };
    for (direct_providers) |provider| {
        try std.testing.expect(!usesGatewayAuxiliaries(provider));
    }
    try std.testing.expect(usesGatewayAuxiliaries(.gateway));
}
