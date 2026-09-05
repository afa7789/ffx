const std = @import("std");
const model_provider = @import("../config/model_provider.zig");

/// The commercial model used by a provider. This is intentionally separate
/// from observed local usage: a provider may not expose its remote balance.
pub const BillingMode = enum {
    subscription,
    api_plan,
    token_plan,
    payg,
    byok,

    pub fn label(self: BillingMode) []const u8 {
        return switch (self) {
            .subscription => "SUBSCRIPTION",
            .api_plan => "API PLAN",
            .token_plan => "TOKEN PLAN",
            .payg => "PAYG",
            .byok => "BYOK",
        };
    }
};

pub const BalanceState = enum {
    unknown,
    healthy,
    warning,
    exhausted,
};

pub const FailureKind = enum {
    authentication,
    plan_exhausted,
    rate_limited,
    provider_unavailable,
    unknown,
};

pub const ProviderStatus = struct {
    provider: model_provider.ProviderId,
    billing: BillingMode,
    balance: BalanceState = .unknown,
    local_cost: f64 = 0,
    local_tokens: u64 = 0,
};

pub fn billingMode(provider: model_provider.ProviderId) BillingMode {
    return switch (provider) {
        .gateway => .api_plan,
        .codex, .grok => .subscription,
        else => .payg,
    };
}

pub fn classifyHttpStatus(status: u16) FailureKind {
    return switch (status) {
        401, 403 => .authentication,
        402 => .plan_exhausted,
        429 => .rate_limited,
        500...599 => .provider_unavailable,
        else => .unknown,
    };
}

pub fn balanceLabel(state: BalanceState) []const u8 {
    return switch (state) {
        .unknown => "Unknown",
        .healthy => "available",
        .warning => "low",
        .exhausted => "exhausted",
    };
}

test "billing modes have stable product labels" {
    try std.testing.expectEqualStrings("SUBSCRIPTION", BillingMode.subscription.label());
    try std.testing.expectEqualStrings("API PLAN", BillingMode.api_plan.label());
    try std.testing.expectEqualStrings("TOKEN PLAN", BillingMode.token_plan.label());
    try std.testing.expectEqualStrings("PAYG", BillingMode.payg.label());
    try std.testing.expectEqualStrings("BYOK", BillingMode.byok.label());
}

test "provider billing mode distinguishes subscriptions and API usage" {
    try std.testing.expectEqual(BillingMode.api_plan, billingMode(.gateway));
    try std.testing.expectEqual(BillingMode.subscription, billingMode(.codex));
    try std.testing.expectEqual(BillingMode.payg, billingMode(.opencode_go));
    try std.testing.expectEqual(BillingMode.payg, billingMode(.deepseek));
}

test "http status classification does not infer exhaustion from unknown responses" {
    try std.testing.expectEqual(FailureKind.authentication, classifyHttpStatus(401));
    try std.testing.expectEqual(FailureKind.plan_exhausted, classifyHttpStatus(402));
    try std.testing.expectEqual(FailureKind.rate_limited, classifyHttpStatus(429));
    try std.testing.expectEqual(FailureKind.provider_unavailable, classifyHttpStatus(503));
    try std.testing.expectEqual(FailureKind.unknown, classifyHttpStatus(400));
}

test "unknown balance is explicit" {
    try std.testing.expectEqualStrings("Unknown", balanceLabel(.unknown));
}
