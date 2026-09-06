const debug_trace = @import("../core/shared/debug_trace.zig");
const std = @import("std");
const openai_direct = @import("../gateway/openai_direct.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_provider = @import("../core/config/model_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");

pub const native = provider_set.Set{
    .gateway = gateway.provider_bundle,
    .direct_selection_fn = directBundle,
    .codex = .{
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .agent_stream = openai_codex.agent_stream_provider,
        .cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .model_catalog = openai_codex_models.model_catalog_provider,
        .permission_reviewer = openai_codex_permission_reviewer.provider,
    },
    .grok = .{
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .agent_stream = xai_grok.agent_stream_provider,
        .cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .model_catalog = xai_grok_models.model_catalog_provider,
        .permission_reviewer = xai_grok_permission_reviewer.provider,
    },
};

pub fn agentStream(provider: model_provider.ProviderId) stream_provider.Provider {
    return switch (provider) {
        // Legacy sentinel: keeps existing sessions and tests working until the
        // direct-provider streams land.
        .gateway => gateway.agent_stream_provider,
        .codex => openai_codex.agent_stream_provider,
        .grok => xai_grok.agent_stream_provider,
        // Direct providers share one OpenAI-compatible chat-completions
        // implementation, parameterized by each registry entry's base URL.
        // Anthropic rides its OpenAI compatibility layer (/v1/chat/
        // completions with Bearer auth); a native Messages-API provider is a
        // separate future module.
        .minimax => directStream("minimax"),
        .openrouter => directStream("openrouter"),
        .ppq => directStream("ppq"),
        .zhipu => directStream("zhipu"),
        .deepseek => directStream("deepseek"),
        .anthropic => directStream("anthropic"),
        .openai => directStream("openai"),
        .opencode_go => directStream("opencode"),
        .zai => directStream("zai"),
        .alibaba_cloud => directStream("alibaba-cloud"),
        .custom => stream_provider.unavailable_provider,
    };
}

fn directStream(comptime id: []const u8) stream_provider.Provider {
    const entry = comptime byId(id).?;
    return openai_direct.agentStreamProvider(.{
        .base_url = entry.default_base_url,
        .fallback_model = entry.default_model,
        .vision_models = comptime visionModels(id),
    });
}

pub fn modelCatalog(provider: model_provider.ProviderId) model_catalog.Provider {
    return switch (provider) {
        .gateway => gateway.model_catalog_provider,
        .codex => openai_codex_models.model_catalog_provider,
        .grok => xai_grok_models.model_catalog_provider,
        // Direct providers fetch {base_url}/models with Bearer auth and fall
        // back to the registry's default_model when the endpoint fails or is
        // absent.
        .minimax => directCatalog("minimax"),
        .openrouter => directCatalog("openrouter"),
        .ppq => directCatalog("ppq"),
        .zhipu => directCatalog("zhipu"),
        .deepseek => directCatalog("deepseek"),
        .anthropic => directCatalog("anthropic"),
        .openai => directCatalog("openai"),
        .opencode_go => directCatalog("opencode"),
        .zai => directCatalog("zai"),
        .alibaba_cloud => directCatalog("alibaba-cloud"),
        .custom => unreachable,
    };
}

fn directCatalog(comptime id: []const u8) model_catalog.Provider {
    const entry = comptime byId(id).?;
    return openai_direct.modelCatalogProvider(.{
        .base_url = entry.default_base_url,
        .fallback_model = entry.default_model,
        .vision_models = comptime visionModels(id),
    });
}

/// Model ids per direct provider that are vision-capable but whose upstream
/// /v1/models omits modality metadata. opencode zen is the known case: it
/// lists models without tags or modalities, so the shared OpenAI-compatible
/// parser cannot infer image support on its own. Providers that publish
/// modalities return an empty list here and keep their catalog-driven
/// decision. Do not add ids you have not verified accept image input.
fn visionModels(comptime id: []const u8) []const []const u8 {
    return if (std.mem.eql(u8, id, "opencode"))
        &[_][]const u8{
            "mimo-v2.5",
            "mimo-v2.5-free",
            "qwen3.8-max",
            "qwen3.8-flash",
            "qwen3.7-max",
            "qwen3.6-plus",
            "kimi-k3",
            "kimi-k2.6",
            "glm-5.3",
            "deepseek-v4-flash-vision-exp",
        }
    else
        &[_][]const u8{};
}

/// `ffx models` catalog routing: fetch the provider's own full catalog and
/// project it to bare model ids, mirroring the codex/grok
/// cli_model_catalog_provider wrappers.
pub fn cliModelCatalog(provider: model_provider.ProviderId) gateway_provider.CliModelCatalogProvider {
    return switch (provider) {
        .gateway => gateway.cli_model_catalog_provider,
        .codex => openai_codex_models.cli_model_catalog_provider,
        .grok => xai_grok_models.cli_model_catalog_provider,
        .minimax => directCliCatalog("minimax"),
        .openrouter => directCliCatalog("openrouter"),
        .ppq => directCliCatalog("ppq"),
        .zhipu => directCliCatalog("zhipu"),
        .deepseek => directCliCatalog("deepseek"),
        .anthropic => directCliCatalog("anthropic"),
        .openai => directCliCatalog("openai"),
        .opencode_go => directCliCatalog("opencode"),
        .zai => directCliCatalog("zai"),
        .alibaba_cloud => directCliCatalog("alibaba-cloud"),
        .custom => unreachable,
    };
}

fn directCliCatalog(comptime id: []const u8) gateway_provider.CliModelCatalogProvider {
    const Impl = struct {
        const catalog_provider = directCatalog(id);
        fn fetch(
            _: ?*anyopaque,
            alloc: std.mem.Allocator,
            input: gateway_provider.CliModelCatalogInput,
        ) gateway_provider.CliModelCatalogResult {
            return switch (model_catalog.fetchWithPublicFallback(catalog_provider, alloc, .{
                .access = input.access,
                .endpoint = input.endpoint,
                .cancel_flag = input.cancel_flag,
                .view = .full,
            })) {
                .loaded => |loaded| blk: {
                    var catalog = loaded.catalog;
                    defer model_catalog.freeModelCatalog(alloc, &catalog);
                    const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                        .access = loaded.provenance.access,
                        .anonymous_fallback_used = false,
                        .failure = .{ .category = .resource_exhausted },
                    } };
                    break :blk .{ .loaded = .{
                        .ids = ids,
                        .provenance = loaded.provenance,
                    } };
                },
                .failed => |failed| .{ .failure = failed },
            };
        }
    };
    return .{ .fetch_fn = Impl.fetch };
}

pub const Provider = struct {
    /// Stable id used in `~/.ffx/settings.json` and the `/provider` command.
    id: []const u8,
    /// Display name shown in the picker and `/provider --list`.
    display_name: []const u8,
    /// Default upstream base URL. Overridable at runtime via
    /// `FFX_PROVIDER_<ID>_BASE_URL` (uppercased id, hyphens replaced with
    /// underscores). The override makes it trivial to point the same provider
    /// at a self-hosted LiteLLM or staging endpoint without recompiling.
    default_base_url: []const u8,
    /// Default model id; ffx hands it to the proxy / upstream. The user can
    /// override per-turn with `FFX_MODEL=<provider>/<model>`. When the
    /// provider exposes a `models_endpoint`, ffx fetches the catalogue
    /// from that path and uses the first entry as the runtime default;
    /// the `default_model` value here is the fallback used when the
    /// catalogue fetch fails or the provider does not expose one.
    default_model: []const u8,
    /// Env var that holds the API key. The provider is considered present
    /// when this env var is set to a non-empty value.
    env_var: []const u8,
    /// Path appended to `default_base_url` to fetch the live model
    /// catalogue. Providers that do not expose a catalogue endpoint
    /// (e.g. self-hosted LiteLLM with no auth) can leave this empty;
    /// `default_model` then becomes the only option.
    models_endpoint: []const u8 = "/v1/models",
};

/// The single source of truth for built-in providers. Order here is the order
/// the picker presents them. Only direct API-key providers appear here;
/// codex and grok are subscription-based and managed by their own modules.
pub const providers = [_]Provider{
    .{
        .id = "minimax",
        .display_name = "MiniMax",
        .default_base_url = "https://api.minimax.io",
        // /v1/models returns M3 at the top, M2.7, M2.5, M2.1, M2 last.
        // M3 is the new default; switch with --model MiniMax-M2-highspeed
        // or any other id from the catalogue.
        .default_model = "MiniMax-M3",
        .env_var = "MINIMAX_API_KEY",
    },
    .{
        .id = "openai",
        .display_name = "OpenAI",
        .default_base_url = "https://api.openai.com",
        .default_model = "gpt-4o-mini",
        .env_var = "OPENAI_API_KEY",
    },
    .{
        .id = "anthropic",
        .display_name = "Anthropic",
        .default_base_url = "https://api.anthropic.com",
        .default_model = "claude-3-5-sonnet-latest",
        .env_var = "ANTHROPIC_API_KEY",
    },
    .{
        // OpenRouter is an aggregator that exposes hundreds of upstream
        // models behind a single OpenAI-compatible endpoint. The default
        // model is the free tier; users usually set FFX_MODEL to
        // "openrouter/<upstream-id>" to pick a specific upstream.
        .id = "openrouter",
        .display_name = "OpenRouter (aggregator)",
        .default_base_url = "https://openrouter.ai/api/v1",
        .default_model = "openrouter/free",
        .env_var = "OPENROUTER_API_KEY",
    },
    .{
        .id = "ppq",
        .display_name = "PPQ",
        .default_base_url = "https://api.ppq.ai/v1",
        .default_model = "claude-sonnet-4.6",
        .env_var = "PPQ_API_KEY",
        .models_endpoint = "/models",
    },
    .{
        // Zhipu is the vendor behind the GLM family. The official endpoint
        // is OpenAI-compatible at /api/paas/v4. Auth is via the Zhipu API
        // console (separate from openai/anthropic).
        .id = "zhipu",
        .display_name = "Zhipu (GLM)",
        .default_base_url = "https://open.bigmodel.cn/api/paas/v4",
        .default_model = "glm-4.5",
        .env_var = "ZHIPU_API_KEY",
    },
    .{
        .id = "deepseek",
        .display_name = "DeepSeek",
        .default_base_url = "https://api.deepseek.com/v1",
        .default_model = "deepseek-chat",
        .env_var = "DEEPSEEK_API_KEY",
    },
    .{
        // OpenCode Zen exposes an OpenAI-compatible endpoint for its shared
        // model catalog. Existing opencode-go keys are loaded as a migration
        // fallback by the credential runtime.
        .id = "opencode",
        .display_name = "OpenCode",
        .default_base_url = "https://opencode.ai/zen/v1",
        .default_model = "deepseek-v4-flash-vision-exp",
        .env_var = "OPENCODE_API_KEY",
    },
    .{
        .id = "zai",
        .display_name = "Z.AI",
        .default_base_url = "https://api.z.ai/api/paas/v4",
        .default_model = "glm-4.5",
        .env_var = "ZAI_API_KEY",
    },
    .{
        .id = "alibaba-cloud",
        .display_name = "Alibaba Cloud",
        .default_base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        .default_model = "qwen-plus",
        .env_var = "DASHSCOPE_API_KEY",
    },
};

/// Returns the provider registered under `id`, or null when unknown.
pub fn byId(id: []const u8) ?Provider {
    for (providers) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

/// Composes the env var name for a per-provider base URL override.
/// `FFX_PROVIDER_<UPPER_ID>_BASE_URL` — e.g. `FFX_PROVIDER_MINIMAX_BASE_URL`.
/// Hyphens in the id are rewritten to underscores so ids like `openai-prod`
/// still produce a valid env var name.
pub fn baseUrlEnvVar(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var upper_buf: [64]u8 = undefined;
    if (id.len > upper_buf.len) return error.ProviderIdTooLong;
    for (id, 0..) |c, i| {
        upper_buf[i] = if (c == '-') '_' else std.ascii.toUpper(c);
    }
    return std.fmt.allocPrint(allocator, "FFX_PROVIDER_{s}_BASE_URL", .{upper_buf[0..id.len]});
}

/// Resolves the effective base URL for `provider`: explicit override via
/// `FFX_PROVIDER_<ID>_BASE_URL` wins, otherwise `provider.default_base_url`.
/// Caller owns the returned slice.
pub fn resolveBaseUrl(allocator: std.mem.Allocator, provider: Provider) ![]u8 {
    const env_var = try baseUrlEnvVar(allocator, provider.id);
    defer allocator.free(env_var);
    if (@import("../core/shared/io.zig").getenv(env_var)) |override| {
        if (std.mem.trim(u8, override, " \t\r\n").len > 0) {
            return allocator.dupe(u8, override);
        }
    }
    return allocator.dupe(u8, provider.default_base_url);
}

/// Calls `<base_url>/v1/models` on the provider and returns the list of
/// model ids the upstream advertises. The shape is the OpenAI-compatible
/// `{ "object": "list", "data": [ { "id": "..." }, ... ] }` envelope;
/// providers that use a different shape return an empty list and the caller
/// falls back to `provider.default_model`. Dispatched by base URL, so it
/// works against any registered provider.
pub fn fetchModels(
    alloc: std.mem.Allocator,
    provider: Provider,
    api_key: []const u8,
    base_url: []const u8,
) ![]const []u8 {
    if (provider.models_endpoint.len == 0) return &[_][]u8{};

    const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{
        base_url,
        provider.models_endpoint,
    });
    defer alloc.free(url);

    const io = @import("../core/shared/io.zig").getIo();
    var client: std.http.Client = .{
        .allocator = alloc,
        .io = io,
    };
    defer client.deinit();

    var auth_buf: [512]u8 = undefined;
    const auth_header = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key});
    const extra = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
    };

    var response_buf: std.Io.Writer.Allocating = .init(alloc);
    defer response_buf.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &extra,
        .response_writer = &response_buf.writer,
        .redirect_behavior = .unhandled,
    }) catch return &[_][]u8{};
    if (result.status != .ok) return &[_][]u8{};
    const body = response_buf.written();

    debug_trace.logf("models", "received default_model={s} base_url={s} response bytes={d}", .{ provider.default_model, base_url, body.len });
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| {
        debug_trace.logf("models", "parse error={s}", .{@errorName(err)});
        return &[_][]u8{};
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        debug_trace.logf("models", "root is not object", .{});
        return &[_][]u8{};
    }
    const data = parsed.value.object.get("data") orelse return &[_][]u8{};
    if (data != .array) return &[_][]u8{};
    var ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }
    for (data.array.items) |entry| {
        if (entry != .object) continue;
        const id = entry.object.get("id") orelse continue;
        if (id != .string) continue;
        if (id.string.len == 0) continue;
        try ids.append(alloc, try alloc.dupe(u8, id.string));
    }
    return ids.toOwnedSlice(alloc);
}

/// Hits the active direct provider's /v1/models catalogue and returns
/// the best fuzzy match for `query`, or null when there is no candidate
/// or the upstream did not return any. Caller owns the returned slice.
/// Falls back to scanning the registry for a provider whose key env
/// is set, the same way the direct-provider credential source does.
/// The catalogue endpoint is provider-native; no gateway intermediary.
pub fn resolveProviderModelQuery(
    alloc: std.mem.Allocator,
    query: []const u8,
) !?[]u8 {
    if (query.len == 0) return null;
    const id = @import("../core/shared/io.zig").getenv("FFX_ACTIVE_PROVIDER");
    const provider = if (id) |explicit| byId(explicit) else null;
    const effective = provider orelse blk: {
        for (providers) |candidate| {
            if (@import("../core/shared/io.zig").getenv(candidate.env_var) != null) {
                break :blk candidate;
            }
        }
        return null;
    };
    const key = @import("../core/shared/io.zig").getenv(effective.env_var) orelse return null;
    const base_url = effective.default_base_url;
    const ids = fetchModels(alloc, effective, key, base_url) catch return null;
    defer {
        for (ids) |id_owned| alloc.free(id_owned);
        alloc.free(ids);
    }
    debug_trace.logf("model", "resolveProviderModelQuery: provider={s} count={d} query={s}", .{ effective.id, ids.len, query });
    if (ids.len == 0) return null;
    // Exact (case-insensitive) match first.
    for (ids) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, query)) {
            return try alloc.dupe(u8, candidate);
        }
    }
    // Substring match: "m3" inside "MiniMax-M3", "gpt-4o" inside
    // "openai/gpt-4o-mini". Case-insensitive.
    for (ids) |candidate| {
        if (std.ascii.indexOfIgnoreCase(candidate, query) != null) {
            return try alloc.dupe(u8, candidate);
        }
    }
    return null;
}

test "fetchModels parses the OpenAI {data:[]} envelope shape" {
    // The parser accepts bodies that look like:
    //   {"object":"list","data":[{"id":"x"},{"id":"y"}]}
    // plus the bare {"data":[...]} shape, and ignores entries that are
    // missing the id string or whose id is empty. We cannot exercise the
    // real HTTP path from a unit test, so we go through the JSON parser
    // directly to assert the contract.
    const body =
        "{\"object\":\"list\",\"data\":[{\"id\":\"alpha\"},{\"id\":\"\"},{\"bad\":1},{\"id\":\"beta\"}]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?;
    var ids: std.ArrayList([]u8) = .empty;
    defer {
        for (ids.items) |id| std.testing.allocator.free(id);
        ids.deinit(std.testing.allocator);
    }
    for (data.array.items) |entry| {
        if (entry != .object) continue;
        const id = entry.object.get("id") orelse continue;
        if (id != .string) continue;
        if (id.string.len == 0) continue;
        try ids.append(std.testing.allocator, try std.testing.allocator.dupe(u8, id.string));
    }
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    try std.testing.expectEqualStrings("alpha", ids.items[0]);
    try std.testing.expectEqualStrings("beta", ids.items[1]);
}

test "byId returns the registered provider or null" {
    try std.testing.expectEqualStrings("minimax", byId("minimax").?.id);
    try std.testing.expectEqualStrings("https://api.minimax.io", byId("minimax").?.default_base_url);
    try std.testing.expectEqualStrings("MINIMAX_API_KEY", byId("minimax").?.env_var);
    try std.testing.expect(byId("does-not-exist") == null);
}

test "baseUrlEnvVar uppercases and rewrites hyphens" {
    const alloc = std.testing.allocator;
    const a = try baseUrlEnvVar(alloc, "minimax");
    defer alloc.free(a);
    const b = try baseUrlEnvVar(alloc, "openai-prod");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("FFX_PROVIDER_MINIMAX_BASE_URL", a);
    try std.testing.expectEqualStrings("FFX_PROVIDER_OPENAI_PROD_BASE_URL", b);
}

test "every registered provider has a non-empty base URL and env var" {
    for (providers) |provider| {
        try std.testing.expect(provider.id.len > 0);
        try std.testing.expect(provider.default_base_url.len > 0);
        try std.testing.expect(provider.env_var.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, provider.default_base_url, "https://") or
            std.mem.startsWith(u8, provider.default_base_url, "http://"));
    }
}

fn directBundle(provider: model_provider.ProviderId) provider_set.Bundle {
    return .{
        .agent_stream = agentStream(provider),
        .model_catalog = modelCatalog(provider),
        .cli_model_catalog = cliModelCatalog(provider),
    };
}
