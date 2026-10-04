// Where the characters and the words of a text begin, as Unicode Standard
// Annex #29 defines them. A character here is what a user sees as one, an
// extended grapheme cluster: a letter with its accents, or an emoji made of
// several code points. Every `text` must be valid UTF-8, and every position
// is a byte offset into it.

const std = @import("std");

const tables = @import("tables.zig");

// The version of the Unicode Standard that the tables are made from.
pub const unicode_version = tables.version;

// The bytes of a text from `start` up to `end`.
pub const Range = struct {
    start: usize,
    end: usize,
};

const Cluster = packed struct(u8) {
    kind: tables.Break,
    conjunct: tables.Conjunct,
    pictographic: bool,
    _: u1,
};

const Word = packed struct(u8) {
    kind: tables.WordBreak,
    pictographic: bool,
    _: u2,
};

// What the run of code points that `point` falls in is, in the lower 8 bits
// of its entry.
fn lookup(table: []const u32, point: u21) u8 {
    var low: usize = 0;
    var high: usize = table.len;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (table[middle] >> 8 <= point) low = middle else high = middle;
    }
    return @truncate(table[low]);
}

fn pointAt(text: []const u8, at: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch unreachable;
    return std.unicode.utf8Decode(text[at..][0..len]) catch unreachable;
}

fn clusterAt(text: []const u8, at: usize) Cluster {
    return @bitCast(lookup(&tables.clusters, pointAt(text, at)));
}

fn wordAt(text: []const u8, at: usize) Word {
    return @bitCast(lookup(&tables.words, pointAt(text, at)));
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

// The starts of the code points after and before the one at `at`.
fn after(text: []const u8, at: usize) usize {
    var next_at = @min(at + 1, text.len);
    while (next_at < text.len and isContinuation(text[next_at])) next_at += 1;
    return next_at;
}

fn before(text: []const u8, at: usize) usize {
    var previous_at = at -| 1;
    while (previous_at > 0 and isContinuation(text[previous_at])) previous_at -= 1;
    return previous_at;
}

fn isControl(kind: tables.Break) bool {
    return kind == .control or kind == .cr or kind == .lf;
}

// GB9c: a consonant joins the one before it across a linker.
fn followsLinker(text: []const u8, at: usize) bool {
    var linked = false;
    var scan = at;
    while (scan > 0) {
        scan = before(text, scan);
        switch (clusterAt(text, scan).conjunct) {
            .linker => linked = true,
            .extend => {},
            .consonant => return linked,
            .none => return false,
        }
    }
    return false;
}

// GB11: a pictograph joins the one before it across a joiner at `joiner`.
fn followsPictograph(text: []const u8, joiner: usize) bool {
    var scan = joiner;
    while (scan > 0) {
        scan = before(text, scan);
        const cluster = clusterAt(text, scan);
        if (cluster.kind != .extend) return cluster.pictographic;
    }
    return false;
}

// Whether a character starts at `at`, or the text ends there.
pub fn isBoundary(text: []const u8, at: usize) bool {
    if (at == 0 or at >= text.len) return true;
    if (isContinuation(text[at])) return false;
    const left_at = before(text, at);
    // Letters, digits and signs of ASCII stand alone.
    if (text[left_at] >= 0x20 and text[left_at] < 0x7f and text[at] >= 0x20 and text[at] < 0x7f) return true;

    const left = clusterAt(text, left_at);
    const right = clusterAt(text, at);
    if (left.kind == .cr and right.kind == .lf) return false;
    if (isControl(left.kind) or isControl(right.kind)) return true;
    const syllable = switch (left.kind) {
        .l => right.kind == .l or right.kind == .v or right.kind == .lv or right.kind == .lvt,
        .lv, .v => right.kind == .v or right.kind == .t,
        .lvt, .t => right.kind == .t,
        else => false,
    };
    if (syllable) return false;
    if (right.kind == .extend or right.kind == .zwj or right.kind == .spacingmark) return false;
    if (left.kind == .prepend) return false;
    if (right.conjunct == .consonant and followsLinker(text, at)) return false;
    if (left.kind == .zwj and right.pictographic and followsPictograph(text, left_at)) return false;
    if (left.kind == .regional_indicator and right.kind == .regional_indicator) {
        // Flags are pairs, counted from the first of the run.
        var count: usize = 0;
        var scan = at;
        while (scan > 0) : (count += 1) {
            scan = before(text, scan);
            if (clusterAt(text, scan).kind != .regional_indicator) break;
        }
        return count % 2 == 0;
    }
    return true;
}

// The start of the character after the one at `at`, or the end of the text.
pub fn next(text: []const u8, at: usize) usize {
    var boundary = after(text, at);
    while (!isBoundary(text, boundary)) boundary = after(text, boundary);
    return boundary;
}

// The start of the character before `at`.
pub fn previous(text: []const u8, at: usize) usize {
    var boundary = before(text, at);
    while (!isBoundary(text, boundary)) boundary = before(text, boundary);
    return boundary;
}

// The start of the character that `at` is in.
pub fn floor(text: []const u8, at: usize) usize {
    var boundary = @min(at, text.len);
    while (!isBoundary(text, boundary)) boundary -= 1;
    return boundary;
}

fn isIgnored(kind: tables.WordBreak) bool {
    return kind == .extend or kind == .format or kind == .zwj;
}

fn isNewline(kind: tables.WordBreak) bool {
    return kind == .newline or kind == .cr or kind == .lf;
}

fn isLetter(kind: tables.WordBreak) bool {
    return kind == .aletter or kind == .hebrew_letter;
}

fn isMidLetter(kind: tables.WordBreak) bool {
    return kind == .midletter or kind == .midnumlet or kind == .single_quote;
}

fn isMidNumber(kind: tables.WordBreak) bool {
    return kind == .midnum or kind == .midnumlet or kind == .single_quote;
}

// WB4: marks and joiners count as part of what they follow, so the rules
// look past them. This moves `at` back to what stands before it and returns
// its kind, or null when nothing does.
fn kindBefore(text: []const u8, at: *usize) ?tables.WordBreak {
    while (at.* > 0) {
        at.* = before(text, at.*);
        const kind = wordAt(text, at.*).kind;
        if (!isIgnored(kind)) return kind;
    }
    return null;
}

// The kind of what stands after the code point at `at`.
fn kindAfter(text: []const u8, at: usize) tables.WordBreak {
    var scan = after(text, at);
    while (scan < text.len) : (scan = after(text, scan)) {
        const kind = wordAt(text, scan).kind;
        if (!isIgnored(kind)) return kind;
    }
    return .other;
}

// Whether a word, a run of spaces or a sign starts at `at`, or the text ends
// there.
pub fn isWordBoundary(text: []const u8, at: usize) bool {
    if (at == 0 or at >= text.len) return true;
    if (isContinuation(text[at])) return false;
    const nearest = wordAt(text, before(text, at)).kind;
    const right = wordAt(text, at);
    if (nearest == .cr and right.kind == .lf) return false;
    if (isNewline(nearest) or isNewline(right.kind)) return true;
    if (nearest == .zwj and right.pictographic) return false;
    if (nearest == .wsegspace and right.kind == .wsegspace) return false;
    if (isIgnored(right.kind)) return false;

    var scan = at;
    const left = kindBefore(text, &scan) orelse return true;
    var run = scan;
    const further = kindBefore(text, &scan) orelse .other;
    const ahead = kindAfter(text, at);
    const b = right.kind;

    if (isLetter(left) and isLetter(b)) return false;
    if (isLetter(left) and isMidLetter(b) and isLetter(ahead)) return false;
    if (isLetter(further) and isMidLetter(left) and isLetter(b)) return false;
    if (left == .hebrew_letter and b == .single_quote) return false;
    if (left == .hebrew_letter and b == .double_quote and ahead == .hebrew_letter) return false;
    if (further == .hebrew_letter and left == .double_quote and b == .hebrew_letter) return false;
    if (left == .numeric and (b == .numeric or isLetter(b))) return false;
    if (isLetter(left) and b == .numeric) return false;
    if (further == .numeric and isMidNumber(left) and b == .numeric) return false;
    if (left == .numeric and isMidNumber(b) and ahead == .numeric) return false;
    if (left == .katakana and b == .katakana) return false;
    const joins = isLetter(left) or left == .numeric or left == .katakana or left == .extendnumlet;
    if (joins and b == .extendnumlet) return false;
    if (left == .extendnumlet and (isLetter(b) or b == .numeric or b == .katakana)) return false;
    if (left == .regional_indicator and b == .regional_indicator) {
        // Flags are pairs, counted from the first of the run.
        var count: usize = 1;
        while (kindBefore(text, &run) == .regional_indicator) count += 1;
        return count % 2 == 0;
    }
    return true;
}

fn isSpace(text: []const u8, at: usize) bool {
    return wordAt(text, at).kind == .wsegspace;
}

// The word, the run of spaces or the sign that `at` is in.
pub fn wordAround(text: []const u8, at: usize) Range {
    var start = @min(at, text.len);
    while (!isWordBoundary(text, start)) start = before(text, start);
    var end = after(text, start);
    while (!isWordBoundary(text, end)) end = after(text, end);
    return .{ .start = start, .end = end };
}

// The end of the word after `at`, past the spaces before that word.
pub fn nextWord(text: []const u8, at: usize) usize {
    var end = at;
    while (end < text.len) {
        const spaces = isSpace(text, end);
        end = wordAround(text, end).end;
        if (!spaces) break;
    }
    return end;
}

// The start of the word before `at`, past the spaces after that word.
pub fn previousWord(text: []const u8, at: usize) usize {
    var start = at;
    while (start > 0) {
        start = wordAround(text, before(text, start)).start;
        if (!isSpace(text, start)) break;
    }
    return start;
}
