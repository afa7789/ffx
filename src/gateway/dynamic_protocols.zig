//! Generic explicit wire adapters. Configuration and credentials belong to core.
const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const definition = @import("../core/provider/definition.zig");
const responses = @import("responses_protocol.zig");
const Allocator = std.mem.Allocator;

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidResponsesModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidResponsesModel;
    }
}

pub fn build_responses(
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }
    if (instructions.written().len == 0) try instructions.writer.writeAll("You are a helpful assistant.");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try writeInput(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    _ = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true,\"include\":[\"reasoning.encrypted_content\"]");
    // Explicit fast preference maps to the public priority service tier.
    if (request.provider_options.fast) try writer.writeAll(",\"service_tier\":\"priority\"");

    try writer.writeAll(",\"text\":{");
    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll("\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":true}");
    }
    try writer.writeByte('}');

    if (request.provider_options.reasoning) |effort| {
        const label = if (std.mem.eql(u8, effort.label(), "minimal")) "low" else effort.label();
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(label, .{}, writer);
        try writer.writeAll(",\"summary\":\"auto\"}");
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeInput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => continue,
            .user => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                if (verified_images) |images| {
                    if (message_index == messages.len - 1) {
                        for (images) |image| {
                            if (!first_part) try writer.writeByte(',');
                            try writeInputImage(writer, alloc, image);
                            first_part = false;
                        }
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                if (message.provider_state_json) |state_json| {
                    var state = std.json.parseFromSlice(std.json.Value, alloc, state_json, .{}) catch
                        return error.InvalidResponsesProviderState;
                    defer state.deinit();
                    if (state.value != .array) return error.InvalidResponsesProviderState;
                    for (state.value.array.items) |item| {
                        if (item != .object) return error.InvalidResponsesProviderState;
                        try writeComma(writer, &first);
                        try std.json.Stringify.value(item, .{}, writer);
                    }
                }
                if (message.content) |content| if (content.len > 0) {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeAll(",\"annotations\":[]}]}");
                };
                for (message.tool_calls) |call| {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"output\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeInputImage(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}");
}

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
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll(",\"strict\":false}");
    return true;
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

/// Caller owns the serialized Messages request.
pub fn build_anthropic(alloc: Allocator, request: stream_provider.BuildRequest) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    if (request.response_format != null) return error.AnthropicStructuredOutputUnsupported;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, w);
    try w.print(",\"stream\":true,\"max_tokens\":{d},\"system\":[", .{request.max_output_tokens orelse 8192});
    var first = true;
    for (request.messages) |message| {
        if (message.role != .system) continue;
        if (message.content) |text| {
            try writeComma(w, &first);
            try write_text(w, text);
        }
    }
    try w.writeAll("],\"messages\":[");
    first = true;
    var last_user: ?usize = null;
    for (request.messages, 0..) |message, i| if (message.role == .user) {
        last_user = i;
    };
    for (request.messages, 0..) |message, i| {
        if (message.role == .system) continue;
        try writeComma(w, &first);
        try w.writeAll("{\"role\":");
        try std.json.Stringify.value(if (message.role == .assistant) "assistant" else "user", .{}, w);
        try w.writeAll(",\"content\":[");
        var first_part = true;
        if (message.role == .tool) {
            try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse return error.MissingToolCallId, .{}, w);
            try w.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, w);
            try w.writeByte('}');
            first_part = false;
        } else if (message.content) |text| if (text.len > 0) {
            try write_text(w, text);
            first_part = false;
        };
        if (message.role == .assistant) for (message.tool_calls) |call| {
            try writeComma(w, &first_part);
            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
            try std.json.Stringify.value(call.id, .{}, w);
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(call.name, .{}, w);
            try w.writeAll(",\"input\":");
            var input = try std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{});
            defer input.deinit();
            if (input.value != .object) return error.InvalidToolArguments;
            try std.json.Stringify.value(input.value, .{}, w);
            try w.writeByte('}');
        };
        if (message.role == .user and last_user == i) if (request.verified_images) |images| for (images) |img| {
            try writeComma(w, &first_part);
            const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(img.bytes.len));
            defer alloc.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, img.bytes);
            try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try std.json.Stringify.value(img.media_type, .{}, w);
            try w.writeAll(",\"data\":");
            try std.json.Stringify.value(encoded, .{}, w);
            try w.writeAll("}}");
        };
        if (first_part) try write_text(w, "");
        try w.writeAll("]}");
    }
    try w.writeByte(']');
    var schemas = try std.json.parseFromSlice(std.json.Value, alloc, request.serialized_tools, .{});
    defer schemas.deinit();
    if (schemas.value != .array) return error.InvalidToolSchema;
    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
    first = true;
    for (schemas.value.array.items) |schema| try write_anthropic_tool(&tools_out.writer, schema, &first);
    for (request.selected_dynamic_tool_schemas) |raw| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
        defer schema.deinit();
        try write_anthropic_tool(&tools_out.writer, schema.value, &first);
    }
    if (!first) {
        try w.writeAll(",\"tools\":[");
        try w.writeAll(tools_out.written());
        try w.writeAll("],\"tool_choice\":{\"type\":");
        const choice = request.tool_choice.label();
        try std.json.Stringify.value(if (std.mem.eql(u8, choice, "required")) "any" else choice, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn write_text(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.writeByte('}');
}

fn write_anthropic_tool(w: *std.Io.Writer, value: std.json.Value, first: *bool) !void {
    if (value != .object) return error.InvalidToolSchema;
    const obj = value.object;
    const kind = string_field(obj, "type") orelse return error.InvalidToolSchema;
    if (!std.mem.eql(u8, kind, "function")) return;
    const name = string_field(obj, "name") orelse return error.InvalidToolSchema;
    const schema = obj.get("inputSchema") orelse obj.get("parameters") orelse return error.InvalidToolSchema;
    if (schema != .object) return error.InvalidToolSchema;
    try writeComma(w, first);
    try w.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, w);
    if (string_field(obj, "description")) |desc| {
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(desc, .{}, w);
    }
    try w.writeAll(",\"input_schema\":");
    try std.json.Stringify.value(schema, .{}, w);
    try w.writeByte('}');
}

const stream_limits: responses.StreamLimits = .{
    .aggregate_bytes = 128 * 1024 * 1024,
    .events = 1_000_000,
    .tool_calls = 4096,
    .tool_identity_bytes = 8192,
    .tool_arguments_bytes = 32 * 1024 * 1024,
    .provider_state_bytes = 32 * 1024 * 1024,
};

/// Uses the common bounded reducer for content and tool accumulation. The
/// Anthropic adapter translates explicit event types, never guesses a protocol.
pub fn consume_sse(protocol: definition.Protocol, alloc: Allocator, reader: *std.Io.Reader, request: stream_provider.Request) !types.GatewayCompletion {
    var reducer = responses.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var framing: SseReader = .{};
    defer framing.pending.deinit(alloc);
    const callbacks: responses.StreamCallbacks = .{
        .context = request.callback_ctx,
        .on_content = request.on_content_chunk,
        .on_tool_start = request.on_tool_start,
        .on_reasoning = request.on_reasoning_chunk,
        .on_tool_input = request.on_tool_input_chunk,
    };
    while (try framing.next(alloc, reader)) |data| {
        defer framing.pending.clearRetainingCapacity();
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (protocol == .anthropic_messages) {
            if (try apply_anthropic(&reducer, alloc, data, callbacks, request)) break;
        } else if (protocol == .openai_responses) {
            if (try reducer.applyJson(alloc, data, callbacks, request.cancel_flag, request.content_capture_limit, stream_limits)) break;
        } else return error.UnsupportedProtocol;
    }
    return reducer.finish(alloc, request.cancel_flag, stream_limits);
}

const SseReader = struct {
    pending: std.ArrayList(u8) = .empty,

    fn next(self: *@This(), alloc: Allocator, reader: *std.Io.Reader) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.SseReadStalled;
                    _ = try responses.checkedAccumulatedSize(self.pending.items.len, buffered.len, 32 * 1024 * 1024);
                    try self.pending.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            const line = if (fragment) |value| blk: {
                _ = try responses.checkedAccumulatedSize(self.pending.items.len, value.len, 32 * 1024 * 1024);
                if (self.pending.items.len == 0) break :blk value;
                try self.pending.appendSlice(alloc, value);
                break :blk self.pending.items;
            } else if (self.pending.items.len > 0) self.pending.items else return null;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "data:")) return std.mem.trim(u8, trimmed[5..], " \t");
            self.pending.clearRetainingCapacity();
        }
    }
};

fn string_field(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn object_field(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return if (v == .object) v.object else null;
}
fn counter(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}

fn apply_anthropic(reducer: *responses.Reducer, alloc: Allocator, raw: []const u8, callbacks: responses.StreamCallbacks, request: stream_provider.Request) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAnthropicEvent;
    const obj = parsed.value.object;
    const kind = string_field(obj, "type") orelse return error.InvalidAnthropicEvent;
    if (std.mem.eql(u8, kind, "error")) return error.AnthropicStreamError;
    reducer.event_count = try responses.checkedAccumulatedSize(reducer.event_count, 1, stream_limits.events);
    reducer.aggregate_bytes = try responses.checkedAccumulatedSize(reducer.aggregate_bytes, raw.len, stream_limits.aggregate_bytes);
    if (std.mem.eql(u8, kind, "message_start")) {
        const message = object_field(obj, "message") orelse return error.InvalidAnthropicEvent;
        if (string_field(message, "id")) |id| {
            if (reducer.generation_id) |old| alloc.free(old);
            reducer.generation_id = try alloc.dupe(u8, id);
        }
        if (object_field(message, "usage")) |usage| {
            reducer.usage.cache_read_tokens = counter(usage, "cache_read_input_tokens");
            reducer.usage.cache_write_tokens = counter(usage, "cache_creation_input_tokens");
            const uncached = counter(usage, "input_tokens");
            reducer.usage.input_tokens = if (uncached) |count| std.math.add(u64, try std.math.add(u64, count, reducer.usage.cache_read_tokens orelse 0), reducer.usage.cache_write_tokens orelse 0) catch return error.InvalidUsage else null;
            reducer.usage.output_tokens = counter(usage, "output_tokens");
        }
        return false;
    }
    if (std.mem.eql(u8, kind, "message_delta")) {
        if (object_field(obj, "usage")) |usage| reducer.usage.output_tokens = counter(usage, "output_tokens") orelse reducer.usage.output_tokens;
        if (object_field(obj, "delta")) |delta| if (string_field(delta, "stop_reason")) |reason| {
            reducer.finish_reason = if (std.mem.eql(u8, reason, "tool_use")) .tool_calls else if (std.mem.eql(u8, reason, "max_tokens")) .length else if (std.mem.eql(u8, reason, "refusal")) .content_filter else .stop;
        };
        return false;
    }
    if (std.mem.eql(u8, kind, "message_stop")) {
        if (reducer.finish_reason == null) return error.StreamIncomplete;
        reducer.terminal_seen = true;
        return true;
    }
    var translated: std.Io.Writer.Allocating = .init(alloc);
    defer translated.deinit();
    const w = &translated.writer;
    const index = counter(obj, "index") orelse 0;
    if (std.mem.eql(u8, kind, "content_block_start")) {
        const block = object_field(obj, "content_block") orelse return error.InvalidAnthropicEvent;
        const block_type = string_field(block, "type") orelse return error.InvalidAnthropicEvent;
        if (!std.mem.eql(u8, block_type, "tool_use")) return false;
        try w.print("{{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"type\":\"function_call\",\"call_id\":", .{index});
        try std.json.Stringify.value(string_field(block, "id") orelse return error.InvalidAnthropicEvent, .{}, w);
        try w.writeAll(",\"name\":");
        try std.json.Stringify.value(string_field(block, "name") orelse return error.InvalidAnthropicEvent, .{}, w);
        try w.writeAll("}}");
    } else if (std.mem.eql(u8, kind, "content_block_delta")) {
        const delta = object_field(obj, "delta") orelse return error.InvalidAnthropicEvent;
        const delta_type = string_field(delta, "type") orelse return error.InvalidAnthropicEvent;
        const mapped: []const u8, const key: []const u8 = if (std.mem.eql(u8, delta_type, "text_delta")) .{ "response.output_text.delta", "text" } else if (std.mem.eql(u8, delta_type, "thinking_delta")) .{ "response.reasoning_text.delta", "thinking" } else if (std.mem.eql(u8, delta_type, "input_json_delta")) .{ "response.function_call_arguments.delta", "partial_json" } else return false;
        try w.writeAll("{\"type\":");
        try std.json.Stringify.value(mapped, .{}, w);
        try w.print(",\"output_index\":{d},\"delta\":", .{index});
        try std.json.Stringify.value(string_field(delta, key) orelse return error.InvalidAnthropicEvent, .{}, w);
        try w.writeByte('}');
    } else return false;
    return reducer.applyJson(alloc, translated.written(), callbacks, request.cancel_flag, request.content_capture_limit, stream_limits);
}

fn test_request(cancel: *std.atomic.Value(bool), delivery: *stream_provider.DeliveryCertainty, evidence: *stream_provider.AttemptEvidence) stream_provider.Request {
    const Ignore = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    return .{ .api_key = "fixture", .team = null, .model = "test", .retry_count = 0, .chat_url = "", .payload = "", .trace_ctx = .{}, .content_capture_limit = null, .delivery = delivery, .attempt_evidence = evidence, .callback_ctx = cancel, .on_content_chunk = Ignore.chunk, .on_tool_start = null, .on_reasoning_chunk = null, .cancel_flag = cancel };
}

test "dynamic protocols serialize real Responses and Anthropic tool history" {
    const alloc = std.testing.allocator;
    const request: stream_provider.BuildRequest = .{
        .model = "private-model",
        .messages = &.{ .{ .role = .system, .content = "Be brief" }, .{ .role = .user, .content = "Read" }, .{ .role = .assistant, .tool_calls = &.{.{ .id = "c1", .name = "read", .arguments_json = "{\"path\":\"a\"}" }} }, .{ .role = .tool, .tool_call_id = "c1", .content = "ok" } },
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read\",\"inputSchema\":{\"type\":\"object\"}}]",
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 123,
    };
    const r = try build_responses(alloc, request);
    defer alloc.free(r);
    var rp = try std.json.parseFromSlice(std.json.Value, alloc, r, .{});
    defer rp.deinit();
    try std.testing.expectEqual(@as(i64, 123), rp.value.object.get("max_output_tokens").?.integer);
    try std.testing.expect(std.mem.find(u8, r, "function_call_output") != null);
    try std.testing.expect(std.mem.find(u8, r, "chat/completions") == null);
    const a = try build_anthropic(alloc, request);
    defer alloc.free(a);
    var ap = try std.json.parseFromSlice(std.json.Value, alloc, a, .{});
    defer ap.deinit();
    try std.testing.expectEqual(@as(i64, 123), ap.value.object.get("max_tokens").?.integer);
    try std.testing.expect(std.mem.find(u8, a, "tool_use_id") != null);
    try std.testing.expect(std.mem.find(u8, a, "input_schema") != null);
}

test "dynamic protocols Responses events stream text tools and usage" {
    var reader: std.Io.Reader = .fixed("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{}\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}}\n\n");
    var cancel = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    const completion = try consume_sse(.openai_responses, std.testing.allocator, &reader, test_request(&cancel, &delivery, &evidence));
    var result: stream_provider.Result = .{ .status = .ok, .completion = completion, .ownership = .owned };
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expectEqualStrings("{}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.input_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "dynamic protocols Anthropic events require message stop and preserve tools usage" {
    var reader: std.Io.Reader = .fixed("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"a1\",\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"read\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n");
    var cancel = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    const request = test_request(&cancel, &delivery, &evidence);
    const completion = try consume_sse(.anthropic_messages, std.testing.allocator, &reader, request);
    var result: stream_provider.Result = .{ .status = .ok, .completion = completion, .ownership = .owned };
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expectEqualStrings("a1", completion.generation_id.?);
    try std.testing.expectEqualStrings("read", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), completion.usage.output_tokens);
    var truncated: std.Io.Reader = .fixed("data: {\"type\":\"message_start\",\"message\":{}}\n\n");
    try std.testing.expectError(error.StreamIncomplete, consume_sse(.anthropic_messages, std.testing.allocator, &truncated, request));
    var failed: std.Io.Reader = .fixed("data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}\n\n");
    try std.testing.expectError(error.AnthropicStreamError, consume_sse(.anthropic_messages, std.testing.allocator, &failed, request));
}
