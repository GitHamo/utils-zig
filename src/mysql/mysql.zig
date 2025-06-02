const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const c = @cImport({
    @cInclude("mysql.h");
});

// Handle deprecated my_bool type - use bool for MySQL 8.0.1+
const MySQLBool = if (@hasDecl(c, "my_bool")) c.my_bool else bool;

const MySQLError = error{
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

const QueryParamType = enum {
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

const DatabaseConfig = struct {
    host: [:0]const u8,
    username: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    port: u16,

    // pub fn init(
    //     allocator: Allocator,
    //     host: ?[]const u8,
    //     username: ?[]const u8,
    //     password: ?[]const u8,
    //     database: ?[]const u8,
    //     port: ?[]const u8,
    // ) !MySQLConfig {
    //     return MySQLConfig{
    //         .host = try allocator.dupeZ(u8, host orelse "127.0.0.1"),
    //         .username = try allocator.dupeZ(u8, username orelse "root"),
    //         .password = try allocator.dupeZ(u8, password orelse ""),
    //         .database = try allocator.dupeZ(u8, database orelse ""),
    //         .port = std.fmt.parseInt(u16, port orelse "3306", 10) catch 3306,
    //     };
    // }

    pub fn deinit(self: *DatabaseConfig, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.username);
        allocator.free(self.password);
        allocator.free(self.database);
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

pub const MySQLDriver = struct {
    allocator: Allocator,
    connection: ?*c.MYSQL,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .connection = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
    }

    pub fn connect(self: *Self, config: DatabaseConfig) MySQLError!void {
        self.connection = c.mysql_init(null);
        if (self.connection == null) {
            return MySQLError.ConnectionFailed;
        }

        const result = c.mysql_real_connect(self.connection, config.host.ptr, config.username.ptr, config.password.ptr, config.database.ptr, config.port, null, 0);

        if (result == null) {
            c.mysql_close(self.connection);
            self.connection = null;
            return MySQLError.ConnectionFailed;
        }
    }

    pub fn disconnect(self: *Self) void {
        if (self.connection) |conn| {
            c.mysql_close(conn);
            self.connection = null;
        }
    }

    pub fn getLastError(self: *Self) ?[]const u8 {
        if (self.connection) |conn| {
            const err_msg = c.mysql_error(conn);
            if (err_msg != null) {
                return std.mem.span(err_msg);
            }
        }

        return null;
    }

    pub fn getAffectedRows(self: *Self) u64 {
        if (self.connection) |conn| {
            return @intCast(c.mysql_affected_rows(conn));
        }

        return 0;
    }

    pub fn getLastInsertId(self: *Self) u64 {
        if (self.connection) |conn| {
            return @intCast(c.mysql_insert_id(conn));
        }

        return 0;
    }

    pub fn execute(self: *Self, query_string: []const u8, params: ?[]const QueryParameter) MySQLError!?QueryResult {
        const stmt = c.mysql_stmt_init(self.connection);
        if (stmt == null) {
            return MySQLError.PrepareStatementFailed;
        }
        defer _ = c.mysql_stmt_close(stmt);

        const query_len = @as(c_ulong, @intCast(query_string.len));

        if (c.mysql_stmt_prepare(stmt, query_string.ptr, query_len) != 0) {
            return MySQLError.PrepareStatementFailed;
        }

        const used_params = params orelse &[_]QueryParameter{};

        if (used_params.len > 0) {
            try self.bindParameters(stmt, used_params);
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            return MySQLError.ExecuteStatementFailed;
        }

        // fetch results if it's a SELECT query
        return try self.fetchResults(stmt);
    }

    fn bindParameters(self: *Self, stmt: *c.MYSQL_STMT, params: []const QueryParameter) MySQLError!void {
        const bind_array = self.allocator.alloc(c.MYSQL_BIND, params.len) catch {
            return MySQLError.OutOfMemory;
        };
        defer self.allocator.free(bind_array);

        @memset(bind_array, std.mem.zeroes(c.MYSQL_BIND));

        for (params, 0..) |param, i| {
            switch (param.value) {
                .String => |str| {
                    bind_array[i].buffer_type = c.MYSQL_TYPE_STRING;
                    bind_array[i].buffer = @constCast(str.ptr);
                    bind_array[i].buffer_length = @intCast(str.len);
                },
                .Integer => |int| {
                    bind_array[i].buffer_type = c.MYSQL_TYPE_LONGLONG;
                    bind_array[i].buffer = @ptrCast(@constCast(&int));
                    bind_array[i].buffer_length = @sizeOf(i64);
                },
                .Float => |float| {
                    bind_array[i].buffer_type = c.MYSQL_TYPE_DOUBLE;
                    bind_array[i].buffer = @ptrCast(@constCast(&float));
                    bind_array[i].buffer_length = @sizeOf(f64);
                },
                .Null => {
                    bind_array[i].buffer_type = c.MYSQL_TYPE_NULL;
                    const null_indicator: MySQLBool = if (MySQLBool == bool) true else 1;
                    bind_array[i].is_null = @ptrCast(@constCast(&null_indicator));
                },
            }
        }

        const bind_result = c.mysql_stmt_bind_param(stmt, bind_array.ptr);
        if (bind_result) {
            return MySQLError.BindParametersFailed;
        }
    }

    fn fetchResults(self: *Self, stmt: *c.MYSQL_STMT) MySQLError!?QueryResult {
        if (c.mysql_stmt_store_result(stmt) != 0) {
            return MySQLError.StoreResultFailed;
        }

        const row_count = c.mysql_stmt_num_rows(stmt);
        if (row_count == 0) {
            const empty_rows = self.allocator.alloc([]const []const u8, 0) catch return MySQLError.OutOfMemory;

            return QueryResult{
                .rows = empty_rows,
                .allocator = self.allocator,
            };
        }

        const result_metadata = c.mysql_stmt_result_metadata(stmt);
        if (result_metadata == null) {
            // No result set (INSERT, UPDATE, DELETE, etc.)
            return null;
        }

        defer c.mysql_free_result(result_metadata);

        const field_count = c.mysql_num_fields(result_metadata);
        if (field_count == 0) {
            return null;
        }

        // Allocate result array
        var results = self.allocator.alloc([]const []const u8, @intCast(row_count)) catch {
            return MySQLError.OutOfMemory;
        };
        errdefer self.allocator.free(results);

        // Setup bind structure for results
        const bind_results = self.allocator.alloc(c.MYSQL_BIND, @intCast(field_count)) catch {
            return MySQLError.OutOfMemory;
        };
        defer self.allocator.free(bind_results);

        const buffers = self.allocator.alloc([*]u8, @intCast(field_count)) catch {
            self.allocator.free(results);
            return MySQLError.OutOfMemory;
        };
        defer {
            for (buffers) |buffer| {
                self.allocator.free(buffer[0..1024]);
            }
            self.allocator.free(buffers);
        }

        const lengths = self.allocator.alloc(c_ulong, @intCast(field_count)) catch {
            return MySQLError.OutOfMemory;
        };
        defer self.allocator.free(lengths);

        const is_null_indicators = self.allocator.alloc(MySQLBool, @intCast(field_count)) catch {
            return MySQLError.OutOfMemory;
        };
        defer self.allocator.free(is_null_indicators);

        // Initialize buffers and bind structure
        @memset(bind_results, std.mem.zeroes(c.MYSQL_BIND));
        const null_init_value: MySQLBool = if (MySQLBool == bool) false else 0;
        @memset(is_null_indicators, null_init_value);

        for (0..@intCast(field_count)) |i| {
            buffers[i] = (self.allocator.alloc(u8, 1024) catch {
                self.allocator.free(results);
                return MySQLError.OutOfMemory;
            }).ptr;

            bind_results[i].buffer_type = c.MYSQL_TYPE_STRING;
            bind_results[i].buffer = buffers[i];
            bind_results[i].buffer_length = 1024;
            bind_results[i].length = &lengths[i];
            bind_results[i].is_null = &is_null_indicators[i];
        }

        const bind_result_status = c.mysql_stmt_bind_result(stmt, bind_results.ptr);
        if (bind_result_status) {
            self.allocator.free(results);
            return MySQLError.FetchResultFailed;
        }

        var row_index: usize = 0;
        while (true) {
            if (c.mysql_stmt_fetch(stmt) != 0) break;

            var row = self.allocator.alloc([]const u8, @intCast(field_count)) catch {
                // Clean up already allocated rows
                for (results[0..row_index]) |prev_row| {
                    for (prev_row) |cell| {
                        if (cell.len > 0) {
                            self.allocator.free(cell);
                        }
                    }
                    self.allocator.free(prev_row);
                }
                return MySQLError.OutOfMemory;
            };

            for (0..@intCast(field_count)) |col| {
                const len = lengths[col];
                const is_null = if (MySQLBool == bool)
                    is_null_indicators[col]
                else
                    is_null_indicators[col] != 0;

                if (is_null) {
                    // Handle NULL values
                    row[col] = "";
                } else {
                    const cell_data = self.allocator.alloc(u8, len) catch {
                        // Clean up current row and previous rows
                        for (row[0..col]) |cell| {
                            if (cell.len > 0) {
                                self.allocator.free(cell);
                            }
                        }
                        self.allocator.free(row);
                        for (results[0..row_index]) |prev_row| {
                            for (prev_row) |cell| {
                                if (cell.len > 0) {
                                    self.allocator.free(cell);
                                }
                            }
                            self.allocator.free(prev_row);
                        }
                        return MySQLError.OutOfMemory;
                    };
                    @memcpy(cell_data, buffers[col][0..len]);
                    row[col] = cell_data;
                }
            }

            results[row_index] = row;
            row_index += 1;
        }

        return QueryResult{
            .rows = results,
            .allocator = self.allocator,
        };
    }
};

pub const Converter = @import("conversion.zig");
