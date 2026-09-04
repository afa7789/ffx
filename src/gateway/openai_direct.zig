//! Direct OpenAI-compatible streaming providers (minimax, openrouter, zhipu,
//! deepseek, anthropic, openai). One implementation parameterized by a static
//! (base_url, fallback_model) config; the API key comes through the normal
//! credential resolution (env var or stored key), never hardcoded.
//!
//! Anthropic note: the native Messages API lives at /v1/messages and is NOT
//! OpenAI-shaped. We deliberately target Anthropic's OpenAI compatibility
//! layer at <base>/v1/chat/completions, which accepts Bearer auth and the
//! standard chat-completions wire format. Switching anthropic to the native
//! Messages schema later means giving it its own module, not growing this one.
const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

const max_error_body_bytes: usize = 1024 * 1024;
const max_sse_line_bytes: usize = 32 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;

/// Static per-provider configuration baked in at comptime by
/// `builtins/providers.zig`. Pointers to configs stay valid for the life of
/// the process, satisfying the Provider.context lifetime contract.
pub const Config = struct {
    /// Default upstream base URL, e.g. "https://api.openai.com" or
    /// "https://openrouter.ai/api/v1". Version-suffixed bases are kept as-is.
    base_url: []const u8,
    /// Catalog fallback when the upstream /models endpoint fails.
    fallback_model: []const u8,
    /// Model ids this provider exposes that are vision-capable. Some
    /// OpenAI-compatible endpoints (notably opencode zen) publish model ids
    /// without any modality metadata in /v1/models, so the shared parser
    /// cannot infer image support. Filling this allowlist for those
    /// endpoints advertises `has_vision` on the matching catalog entries.
    /// Empty by default; leave it empty for providers that do publish
    /// modalities, so their catalog drives the decision.
    vision_models: []const []const u8 = &.{},
};

/// Appends the chat-completions path to a provider base URL. Bases that
/// already end in a version segment (e.g. ".../v1", ".../api/paas/v4")
/// get "/chat/completions"; bare hosts get "/v1/chat/completions".
pub fn chatCompletionsUrl(alloc: Allocator, base_url: []const u8) ![]u8 {
    const path: []const u8 = if (hasVersionSegment(base_url))
        "/chat/completions"
    else
        "/v1/chat/completions";
    return std.mem.concat(alloc, u8, &.{ trimTrailingSlashes(base_url), path });
}

/// Appends the model-catalog path to a provider base URL, mirroring
/// `chatCompletionsUrl`'s version-segment rule.
pub fn modelsUrl(alloc: Allocator, base_url: []const u8) ![]u8 {
    const path: []const u8 = if (hasVersionSegment(base_url)) "/models" else "/v1/models";
    return std.mem.concat(alloc, u8, &.{ trimTrailingSlashes(base_url), path });
}

fn trimTrailingSlashes(base_url: []const u8) []const u8 {
    var trimmed = base_url;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    return trimmed;
}

fn hasVersionSegment(base_url: []const u8) bool {
    const trimmed = trimTrailingSlashes(base_url);
    const slash = std.mem.findScalarLast(u8, trimmed, '/') orelse return false;
    const segment = trimmed[slash + 1 ..];
    if (segment.len < 2 or segment[0] != 'v') return false;
    for (segment[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Builds a static-context stream provider for one direct provider.
pub fn agentStreamProvider(comptime config: Config) stream_provider.Provider {
    return .{
        .context = @ptrCast(@constCast(&config)),
        .build_fn = buildRequest,
        .stream_fn = streamCompletion,
    };
}

/// Builds a static-context catalog provider for one direct provider. Falls
/// back to the configured `fallback_model` whenever the live /models fetch
/// fails for any reason, so the picker always has at least one option.
pub fn modelCatalogProvider(comptime config: Config) model_catalog.Provider {
    return .{
        .context = @ptrCast(@constCast(&config)),
        .fetch_fn = fetchCatalog,
    };
}

fn configFrom(ctx: ?*anyopaque) *const Config {
    return @ptrCast(@alignCast(ctx.?));
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAIDirectModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAIDirectModel;
    }
}

pub fn buildRequest(
    ctx: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    _ = ctx;
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"messages\":[");

    var first = true;
    // System messages are joined into one leading system message, matching
    // the codex provider's instruction handling.
    var system_text: std.Io.Writer.Allocating = .init(alloc);
    defer system_text.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (system_text.written().len > 0) try system_text.writer.writeAll("\n\n");
        try system_text.writer.writeAll(text);
    }
    if (system_text.written().len > 0) {
        try writer.writeAll("{\"role\":\"system\",\"content\":");
        try std.json.Stringify.value(system_text.written(), .{}, writer);
        try writer.writeByte('}');
        first = false;
    }

    const last_user_index: ?usize = blk: {
        var index: ?usize = null;
        for (request.messages, 0..) |message, i| {
            if (message.role == .user) index = i;
        }
        break :blk index;
    };

    for (request.messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => continue,
            .user => {
                if (!first) try writer.writeByte(',');
                first = false;
                const has_images = request.verified_images != null and
                    request.verified_images.?.len > 0 and
                    last_user_index == message_index;
                if (has_images) {
                    try writer.writeAll("{\"role\":\"user\",\"content\":[");
                    var first_part = true;
                    if (message.content) |content| if (content.len > 0) {
                        try writer.writeAll("{\"type\":\"text\",\"text\":");
                        try std.json.Stringify.value(content, .{}, writer);
                        try writer.writeByte('}');
                        first_part = false;
                    };
                    for (request.verified_images.?) |image| {
                        if (!first_part) try writer.writeByte(',');
                        first_part = false;
                        try writeImageUrl(writer, alloc, image);
                    }
                    try writer.writeAll("]}");
                } else {
                    try writer.writeAll("{\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .assistant => {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.writeAll("{\"role\":\"assistant\"");
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll(",\"content\":");
                    try std.json.Stringify.value(content, .{}, writer);
                };
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, i| {
                        if (i > 0) try writer.writeByte(',');
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(call.arguments_json, .{}, writer);
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
    try writer.writeByte(']');

    const tool_count = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    }

    if (request.max_output_tokens) |max_tokens| {
        try writer.writeAll(",\"max_tokens\":");
        try writer.print("{d}", .{max_tokens});
    }
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
    }

    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }

    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeImageUrl(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

/// Converts AI SDK-style serialized tool schemas into the OpenAI chat
/// completions `{"type":"function","function":{...}}` shape. Returns the
/// number of tools written.
fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
    selected_dynamic_schemas: []const []const u8,
) !usize {
    var count: usize = 0;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolSchema;

    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
    try tools_out.writer.writeAll(",\"tools\":[");
    for (parsed.value.array.items) |tool| {
        if (try writeFunctionTool(&tools_out.writer, tool, count != 0)) count += 1;
    }
    for (selected_dynamic_schemas) |schema_json| {
        var selected = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolSchema,
        };
        defer selected.deinit();
        if (try writeFunctionTool(&tools_out.writer, selected.value, count != 0)) count += 1;
    }
    try tools_out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(tools_out.written());
    return count;
}

fn writeFunctionTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const kind = value.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = value.object.get("inputSchema") orelse value.object.get("parameters") orelse return false;
    if (parameters != .object) return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll("}}");
    return true;
}

fn streamCompletion(
    ctx: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    const config = configFrom(ctx);
    return streamCompletionCore(config, alloc, request) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: []const u8,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "text/event-stream" },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(
    config: *const Config,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.api_key.len == 0) return error.OpenAIDirectCredentialRequired;
    try validateModel(request.model);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);

    const request_endpoint = try chatCompletionsUrl(alloc, config.base_url);
    defer alloc.free(request_endpoint);
    const uri = try std.Uri.parse(request_endpoint);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
    };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        try gateway_client.spawnHttpCancelWatcher(
            &cancel_watch_done,
            request.cancel_flag,
            connection.stream_writer.stream,
        )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = request.payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(request.payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI-compatible provider error response exceeded the local limit"),
            else => return err,
        };
        return .{
            .status = response.head.status,
            .err_body = body,
            .ownership = .owned,
        };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const completion = try consumeSse(
        alloc,
        reader,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.on_tool_input_chunk,
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{
        .status = .ok,
        .completion = completion,
        .generation_origin = config.base_url,
        .ownership = .owned,
    };
}

const ToolAccumulator = struct {
    index: i64,
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

/// Shared SSE line reader. Emits each `data:` payload; comments, blank lines,
/// and `[DONE]` terminate the stream. Copied from the codex provider.
const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAIDirectSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenAIDirectSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return self.pending_line.items;
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.OpenAIDirectSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return fragment;
            try self.pending_line.appendSlice(alloc, fragment);
            return self.pending_line.items;
        }
    }
};

/// Parses an OpenAI chat-completions SSE stream into a GatewayCompletion,
/// forwarding deltas through the streaming callbacks as they arrive.
pub fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var failed_event = false;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidOpenAIDirectSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event = parsed.value.object;

        if (event.get("error")) |error_value| {
            if (error_value != .null) {
                failed_event = true;
                break;
            }
        }
        if (event.get("id")) |id_value| {
            if (id_value == .string and generation_id == null) {
                generation_id = try alloc.dupe(u8, id_value.string);
            }
        }
        if (event.get("usage")) |usage_value| {
            if (usage_value == .object) usage = parseUsage(usage_value.object);
        }

        const choices = event.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;

        if (choice.object.get("finish_reason")) |reason_value| {
            if (reason_value == .string) {
                finish_reason = finishReason(reason_value.string, tools.items.len > 0);
            }
        }

        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        if (delta.object.get("content")) |content_value| {
            if (content_value == .string and content_value.string.len > 0) {
                on_content_chunk(callback_ctx, content_value.string);
                try appendCaptured(alloc, &content, content_value.string, content_capture_limit);
            }
        }
        const reasoning = blk: {
            if (delta.object.get("reasoning_content")) |value| {
                if (value == .string) break :blk value.string;
            }
            if (delta.object.get("reasoning")) |value| {
                if (value == .string) break :blk value.string;
            }
            break :blk null;
        };
        if (reasoning) |reasoning_text| {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, reasoning_text);
        }
        if (delta.object.get("tool_calls")) |tool_calls_value| {
            if (tool_calls_value == .array) {
                for (tool_calls_value.array.items) |call_value| {
                    if (call_value != .object) continue;
                    try accumulateToolCall(
                        alloc,
                        &tools,
                        call_value.object,
                        callback_ctx,
                        on_tool_start,
                        on_tool_input_chunk,
                    );
                }
            }
        }
    }
    if (failed_event) return error.OpenAIDirectStreamFailed;
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = if (tools.items.len > 0)
        try alloc.alloc(types.ToolCall, tools.items.len)
    else
        &.{};
    errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
    var initialized: usize = 0;
    errdefer for (owned_tools[0..initialized]) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
    };
    for (tools.items, 0..) |*tool, index| {
        const arguments = if (tool.arguments.items.len > 0)
            try tool.arguments.toOwnedSlice(alloc)
        else
            try alloc.dupe(u8, "{}");
        tool.arguments = .empty;
        owned_tools[index] = .{
            .id = tool.id,
            .name = tool.name,
            .arguments_json = arguments,
        };
        tool.id = &.{};
        tool.name = &.{};
        initialized += 1;
    }
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
        .usage = usage,
    };
}

fn accumulateToolCall(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    call: std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
) !void {
    const index_value = call.get("index") orelse return;
    if (index_value != .integer) return;
    const index = index_value.integer;

    var existing = findTool(tools.items, index);
    if (existing == null) {
        const id = if (call.get("id")) |id_value|
            if (id_value == .string) try alloc.dupe(u8, id_value.string) else try alloc.dupe(u8, "")
        else
            try alloc.dupe(u8, "");
        errdefer alloc.free(id);
        const name = if (call.get("function")) |function_value| blk: {
            if (function_value == .object) {
                if (function_value.object.get("name")) |name_value| {
                    if (name_value == .string) break :blk try alloc.dupe(u8, name_value.string);
                }
            }
            break :blk try alloc.dupe(u8, "");
        } else try alloc.dupe(u8, "");
        errdefer alloc.free(name);
        try tools.append(alloc, .{ .index = index, .id = id, .name = name });
        existing = tools.items.len - 1;
        const started_id = tools.items[existing.?].id;
        const started_name = tools.items[existing.?].name;
        if (started_name.len > 0) {
            if (on_tool_start) |callback| callback(callback_ctx, started_id, started_name, null);
        }
    }

    const tool = &tools.items[existing.?];
    if (call.get("id")) |id_value| {
        if (id_value == .string and id_value.string.len > 0 and tool.id.len == 0) {
            const replaced = try alloc.dupe(u8, id_value.string);
            alloc.free(tool.id);
            tool.id = replaced;
        }
    }
    if (call.get("function")) |function_value| {
        if (function_value == .object) {
            if (function_value.object.get("name")) |name_value| {
                if (name_value == .string and name_value.string.len > 0 and tool.name.len == 0) {
                    const replaced = try alloc.dupe(u8, name_value.string);
                    alloc.free(tool.name);
                    tool.name = replaced;
                    if (on_tool_start) |callback| callback(callback_ctx, tool.id, tool.name, null);
                }
            }
            if (function_value.object.get("arguments")) |arguments_value| {
                if (arguments_value == .string and arguments_value.string.len > 0) {
                    try tool.arguments.appendSlice(alloc, arguments_value.string);
                    if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments_value.string);
                }
            }
        }
    }
}

fn appendCaptured(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn findTool(tools: []const ToolAccumulator, index: i64) ?usize {
    for (tools, 0..) |tool, tool_index| if (tool.index == index) return tool_index;
    return null;
}

fn finishReason(reason: []const u8, has_tools: bool) types.ProviderFinishReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) {
        return .tool_calls;
    }
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    return if (has_tools) .tool_calls else .other;
}

fn parseUsage(object: std.json.ObjectMap) types.Usage {
    // OpenAI wire format uses prompt_tokens/completion_tokens; several
    // compatible deployments also accept input_tokens/output_tokens.
    return .{
        .input_tokens = unsignedField(object, "prompt_tokens") orelse unsignedField(object, "input_tokens"),
        .output_tokens = unsignedField(object, "completion_tokens") orelse unsignedField(object, "output_tokens"),
    };
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

const CatalogFetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *CatalogFetchResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

const CatalogFetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,

    pub fn run(self: *@This()) !CatalogFetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        var response_writer = std.Io.Writer.Allocating.initCapacity(self.alloc, max_catalog_bytes + 1) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
            },
            .response_writer = &response_writer.writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenAIDirectCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.written();
        if (body.len > max_catalog_bytes) return error.OpenAIDirectCatalogTooLarge;
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn fetchCatalog(
    ctx: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const config = configFrom(ctx);
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };

    const request_url = try modelsUrl(alloc, config.base_url);
    defer alloc.free(request_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    var operation = CatalogFetchOperation{
        .alloc = alloc,
        .url = request_url,
        .credential = credential,
    };
    var response = gateway_client.runBoundedHttpOperation(
        CatalogFetchResponse,
        alloc,
        cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(fetch_timeout_ms),
        }),
        &operation,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) {
            return .{ .failure = .{ .category = .cancellation } };
        }
        return .{ .catalog = try fallbackCatalog(alloc, config.fallback_model, config.vision_models) };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .catalog = try fallbackCatalog(alloc, config.fallback_model, config.vision_models) };
    }
    var catalog = parseCatalog(alloc, response.body, config.vision_models) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .catalog = try fallbackCatalog(alloc, config.fallback_model, config.vision_models) };
    };
    if (catalog.items.len == 0) {
        model_catalog.freeModelCatalog(alloc, &catalog);
        return .{ .catalog = try fallbackCatalog(alloc, config.fallback_model, config.vision_models) };
    }
    return .{ .catalog = catalog };
}

fn parseCatalog(
    alloc: Allocator,
    json_text: []const u8,
    vision_models: []const []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenAIDirectCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenAIDirectCatalog;
    if (data != .array) return error.InvalidOpenAIDirectCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |entry| {
        if (entry != .object) continue;
        const id_value = entry.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0) continue;
        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const has_vision = containsModelId(vision_models, id_value.string);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            // Compat endpoints do not advertise capabilities uniformly;
            // assume the common agentic baseline.
            .has_tool_use = true,
            .has_vision = has_vision,
            .has_file_input = has_vision,
        });
    }
    return catalog;
}

fn containsModelId(models: []const []const u8, needle: []const u8) bool {
    for (models) |candidate| {
        if (std.mem.eql(u8, candidate, needle)) return true;
    }
    return false;
}

fn fallbackCatalog(
    alloc: Allocator,
    fallback_model: []const u8,
    vision_models: []const []const u8,
) Allocator.Error!std.ArrayList(model_catalog.ModelCatalogEntry) {
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    if (fallback_model.len == 0) return catalog;
    const id = try alloc.dupe(u8, fallback_model);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    const has_vision = containsModelId(vision_models, fallback_model);
    try catalog.append(alloc, .{ .id = id, .model_type = model_type, .has_tool_use = true, .has_vision = has_vision, .has_file_input = has_vision });
    return catalog;
}

test "chatCompletionsUrl keeps existing version segments and adds v1 to bare hosts" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { base: []const u8, expected: []const u8 }{
        .{ .base = "https://api.openai.com", .expected = "https://api.openai.com/v1/chat/completions" },
        .{ .base = "https://api.minimax.io", .expected = "https://api.minimax.io/v1/chat/completions" },
        .{ .base = "https://api.anthropic.com", .expected = "https://api.anthropic.com/v1/chat/completions" },
        .{ .base = "https://openrouter.ai/api/v1", .expected = "https://openrouter.ai/api/v1/chat/completions" },
        .{ .base = "https://api.deepseek.com/v1", .expected = "https://api.deepseek.com/v1/chat/completions" },
        .{ .base = "https://open.bigmodel.cn/api/paas/v4/", .expected = "https://open.bigmodel.cn/api/paas/v4/chat/completions" },
    };
    for (cases) |case| {
        const url = try chatCompletionsUrl(alloc, case.base);
        defer alloc.free(url);
        try std.testing.expectEqualStrings(case.expected, url);
    }
}

test "modelsUrl mirrors the version-segment rule" {
    const alloc = std.testing.allocator;
    const bare = try modelsUrl(alloc, "https://api.openai.com");
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/models", bare);
    const versioned = try modelsUrl(alloc, "https://openrouter.ai/api/v1");
    defer alloc.free(versioned);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/models", versioned);
}

test "direct request builds chat-completions body with system join and tool history" {
    const config = comptime Config{ .base_url = "https://api.openai.com", .fallback_model = "gpt-4o-mini" };
    const provider = comptime agentStreamProvider(config);
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try provider.build(std.testing.allocator, .{
        .model = "deepseek-chat",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-chat\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"system\",\"content\":\"Be concise.\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"user\",\"content\":\"Read it.\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\"") != null);
    // No reasoning effort requested: field must stay absent.
    try std.testing.expect(std.mem.find(u8, body, "reasoning_effort") == null);
}

test "direct request omits tool_choice without tools and maps reasoning effort" {
    const config = comptime Config{ .base_url = "https://api.deepseek.com/v1", .fallback_model = "deepseek-chat" };
    const provider = comptime agentStreamProvider(config);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try provider.build(std.testing.allocator, .{
        .model = "deepseek-reasoner",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\":\"high\"") != null);
}

test "direct SSE parses deltas reasoning tool calls usage and finish reason" {
    const sse_text =
        "data: {\"id\":\"gen_1\",\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,
        tool_input: std.ArrayList(u8) = .empty,
        saw_read_file: bool = false,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn reasoningChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reasoning.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolInputChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_input.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saw_read_file = std.mem.eql(u8, name, "read_file");
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    defer capture.reasoning.deinit(std.testing.allocator);
    defer capture.tool_input.deinit(std.testing.allocator);
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.contentChunk,
        Capture.toolStart,
        Capture.reasoningChunk,
        Capture.toolInputChunk,
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expectEqualStrings("thinking", capture.reasoning.items);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", capture.tool_input.items);
    try std.testing.expect(capture.saw_read_file);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("gen_1", completion.generation_id.?);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.output_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "direct SSE treats plain stop without terminal event as a complete stream" {
    const sse_text =
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        fn ignore(_: *anyopaque, _: []const u8) void {}
    };
    var capture: Capture = .{};
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.ignore,
        null,
        null,
        null,
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqualStrings("hi", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
}

test "direct catalog parser reads the OpenAI data envelope and skips junk entries" {
    const alloc = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"MiniMax-M3","object":"model"},
        \\  {"id":""},
        \\  {"bad":1},
        \\  {"id":"MiniMax-M2.5"}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, json, &.{});
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("MiniMax-M3", catalog.items[0].id);
    try std.testing.expectEqualStrings("language", catalog.items[0].model_type);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(!catalog.items[0].has_vision);
    try std.testing.expectEqualStrings("MiniMax-M2.5", catalog.items[1].id);
}

test "direct catalog parser marks vision for allowlisted model ids only" {
    const alloc = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"mimo-v2.5","object":"model"},
        \\  {"id":"deepseek-chat","object":"model"}
        \\]}
    ;
    const vision_models = [_][]const u8{ "mimo-v2.5", "mimo-v2.5-free" };
    var catalog = try parseCatalog(alloc, json, &vision_models);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("mimo-v2.5", catalog.items[0].id);
    try std.testing.expect(catalog.items[0].has_vision);
    try std.testing.expect(catalog.items[0].has_file_input);
    try std.testing.expectEqualStrings("deepseek-chat", catalog.items[1].id);
    try std.testing.expect(!catalog.items[1].has_vision);
    try std.testing.expect(!catalog.items[1].has_file_input);
}

test "direct fallback catalog yields exactly the registered default model" {
    var catalog = try fallbackCatalog(std.testing.allocator, "glm-4.5", &.{});
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("glm-4.5", catalog.items[0].id);
    try std.testing.expect(!catalog.items[0].has_vision);

    const vision_models = [_][]const u8{"mimo-v2.5"};
    var vision = try fallbackCatalog(std.testing.allocator, "mimo-v2.5", &vision_models);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &vision);
    try std.testing.expectEqual(@as(usize, 1), vision.items.len);
    try std.testing.expect(vision.items[0].has_vision);
    try std.testing.expect(vision.items[0].has_file_input);
}
