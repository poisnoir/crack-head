const stringError = error{
    outOfBound,
};

pub const string = struct {
    data: [64]u8,
    len: u8,

    pub fn equal(a: *@This(), b: *@This()) bool {
        if (a.len != b.len) {
            return false;
        }

        for (0..a.len) |i| {
            if (a.data[i] != b.data[i]) {
                return false;
            }
        }
        return true;
    }

    pub fn default() @This() {
        return .{
            .data = undefined,
            .len = 0,
        };
    }

    pub fn fromConst(data: []const u8) stringError!@This() {
        if (data.len > 64) {
            return stringError.outOfBound;
        }

        var result: @This() = default();
        @memcpy(result.data[0..data.len], data);
        result.len = @intCast(data.len);
        return result;
    }
};
