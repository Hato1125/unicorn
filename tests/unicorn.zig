const std = @import("std");
const unicorn = @import("unicorn");

const gpa = std.testing.allocator;

// Runs a test file of the Unicode Character Database: every line holds code
// points with ÷ where a boundary is and × where none is.
fn conform(comptime file: []const u8, comptime isBoundary: fn ([]const u8, usize) bool) !void {
    var lines = std.mem.splitScalar(u8, @embedFile(file), '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var boundaries: std.ArrayList(usize) = .empty;
        defer boundaries.deinit(gpa);

        var tokens = std.mem.tokenizeAny(u8, std.mem.sliceTo(line, '#'), " \t\r");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                try boundaries.append(gpa, text.items.len);
            } else if (!std.mem.eql(u8, token, "×")) {
                var encoded: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(try std.fmt.parseInt(u21, token, 16), &encoded);
                try text.appendSlice(gpa, encoded[0..len]);
            }
        }

        if (text.items.len == 0) continue;

        for (0..text.items.len + 1) |at| {
            const expected = std.mem.indexOfScalar(usize, boundaries.items, at) != null;
            if (isBoundary(text.items, at) != expected) {
                std.debug.print("{s}:{d}, byte {d}: {s}\n", .{ file, number, at, line });
                return error.BoundaryMismatch;
            }
        }
    }
}

test "characters begin where the Unicode test file says" {
    try conform("data/GraphemeBreakTest.txt", unicorn.isBoundary);
}

test "words begin where the Unicode test file says" {
    try conform("data/WordBreakTest.txt", unicorn.isWordBoundary);
}

test "a character is skipped as a whole in both directions" {
    const text = "aか\u{3099}👨‍👩‍👧‍👦🇯🇵z";
    var forward: [5]usize = undefined;
    var at: usize = 0;
    for (&forward) |*stop| {
        at = unicorn.next(text, at);
        stop.* = at;
    }
    try std.testing.expectEqualSlices(usize, &.{ 1, 7, 32, 40, 41 }, &forward);

    for (0..forward.len) |i| {
        const stop = forward[forward.len - 1 - i];
        try std.testing.expectEqual(if (i == forward.len - 1) 0 else forward[forward.len - 2 - i], unicorn.previous(text, stop));
    }
    try std.testing.expectEqual(@as(usize, 7), unicorn.floor(text, 20));
}

test "a step by word passes the spaces and stops at the end of a word" {
    const text = "one  two, 三つ";
    try std.testing.expectEqual(@as(usize, 3), unicorn.nextWord(text, 0));
    try std.testing.expectEqual(@as(usize, 8), unicorn.nextWord(text, 3));
    try std.testing.expectEqual(@as(usize, 9), unicorn.nextWord(text, 8));
    try std.testing.expectEqual(@as(usize, 5), unicorn.previousWord(text, 8));
    try std.testing.expectEqual(@as(usize, 0), unicorn.previousWord(text, 5));
    try std.testing.expectEqual(@as(usize, 0), unicorn.previousWord(text, 2));
    try std.testing.expectEqual(text.len, unicorn.nextWord(text, text.len));

    const word = unicorn.wordAround(text, 6);
    try std.testing.expectEqualStrings("two", text[word.start..word.end]);
}
