const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("mysql.h");
});

// Handle deprecated my_bool type - use bool for MySQL 8.0.1+
pub const MySQLBool = if (@hasDecl(c, "my_bool")) c.my_bool else bool;

pub const DriverError = error{
    ConnectionFailed,
    QueryFailed,
    PrepareStatementFailed,
    BindParametersFailed,
    ExecuteStatementFailed,
    StoreResultFailed,
    FetchResultFailed,
    OutOfMemory,
    InvalidParameterType,
    ExecuteFailed,
};

pub const QueryParamType = enum {
    String,
    Integer,
    Float,
    Null,
};

pub const QueryParameter = struct {
    value: union(QueryParamType) {
        String: []const u8,
        Integer: i64,
        Float: f64,
        Null: void,
    },

    pub fn fromString(str: []const u8) QueryParameter {
        return QueryParameter{ .value = .{ .String = str } };
    }

    pub fn fromInt(int: i64) QueryParameter {
        return QueryParameter{ .value = .{ .Integer = int } };
    }

    pub fn fromFloat(float: f64) QueryParameter {
        return QueryParameter{ .value = .{ .Float = float } };
    }

    pub fn fromNull() QueryParameter {
        return QueryParameter{ .value = .{ .Null = {} } };
    }
};

pub const QueryResult = struct {
    rows: [][]const []const u8,
    allocator: Allocator,

    pub fn deinit(self: *QueryResult) void {
        // Free each cell in each row
        for (self.rows) |row| {
            for (row) |cell| {
                if (cell.len > 0) {
                    self.allocator.free(cell);
                }
            }
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
    }
};

pub const DatabaseConfig = struct {
    host: [:0]const u8,
    username: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    port: u16,

    pub fn deinit(self: *DatabaseConfig, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.username);
        allocator.free(self.password);
        allocator.free(self.database);
    }
};
