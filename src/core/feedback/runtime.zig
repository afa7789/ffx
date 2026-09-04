const std = @import("std");

pub const url = "https://ffx.sh/feedback";

test "feedback URL stays on the ffx.sh domain" {
    try std.testing.expectEqualStrings("https://ffx.sh/feedback", url);
}
