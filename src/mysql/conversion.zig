const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ConversionError = error{
    InvalidFieldCount,
    ParseError,
    OutOfMemory,
    UnsupportedType,
};

/// Converts QueryResult rows into an array of structs of the specified type
/// T: The target struct type
/// allocator: Memory allocator for the result array
/// result: QueryResult containing the data rows
/// Returns: Allocated slice of structs (caller owns memory)
pub fn convertQueryResult(comptime T: type, allocator: Allocator, result: anytype) ![]T {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Target type must be a struct");
    }
    
    const fields = std.meta.fields(T);

    // Allocate array for results
    var converted_rows = try allocator.alloc(T, result.rows.len);
    errdefer allocator.free(converted_rows);
    
    for (result.rows, 0..) |row, row_idx| {
        if (row.len != fields.len) {
            std.debug.print("Error: Row {d} has {d} columns, expected {d}\n", .{ row_idx, row.len, fields.len });
            return ConversionError.InvalidFieldCount;
        }
        
        var struct_instance: T = undefined;
        
        // Use inline for to iterate over struct fields at compile time
        inline for (fields, 0..) |field, field_idx| {
            const field_value = try convertField(field.type, row[field_idx], allocator);
            @field(struct_instance, field.name) = field_value;
        }
        
        converted_rows[row_idx] = struct_instance;
    }
    
    return converted_rows;
}

/// Converts a string value to the target field type
fn convertField(comptime FieldType: type, value: []const u8, allocator: Allocator) !FieldType {
    const type_info = @typeInfo(FieldType);
    
    switch (type_info) {
        .pointer => |ptr_info| {
            if (ptr_info.child == u8 and ptr_info.size == .slice) {
                // String field - duplicate the value so it's owned by our allocator
                return try allocator.dupe(u8, value);
            } else {
                return ConversionError.UnsupportedType;
            }
        },
        .int => |_| {
            if (value.len == 0) {
                return 0; // Handle empty/null values
            }
            return std.fmt.parseInt(FieldType, value, 10) catch |err| {
                std.debug.print("Failed to parse '{}' as {}: {}\n", .{ std.zig.fmtEscapes(value), FieldType, err });
                return ConversionError.ParseError;
            };
        },
        .float => {
            if (value.len == 0) {
                return 0.0; // Handle empty/null values
            }
            return std.fmt.parseFloat(FieldType, value) catch |err| {
                std.debug.print("Failed to parse '{}' as {}: {}\n", .{ std.zig.fmtEscapes(value), FieldType, err });
                return ConversionError.ParseError;
            };
        },
        .bool => {
            if (value.len == 0) {
                return false;
            }
            // Handle various boolean representations
            const lower_value = std.ascii.allocLowerString(allocator, value) catch return ConversionError.OutOfMemory;
            defer allocator.free(lower_value);
            
            if (std.mem.eql(u8, lower_value, "true") or 
                std.mem.eql(u8, lower_value, "1") or 
                std.mem.eql(u8, lower_value, "yes") or 
                std.mem.eql(u8, lower_value, "on")) {
                return true;
            } else if (std.mem.eql(u8, lower_value, "false") or 
                       std.mem.eql(u8, lower_value, "0") or 
                       std.mem.eql(u8, lower_value, "no") or 
                       std.mem.eql(u8, lower_value, "off")) {
                return false;
            } else {
                return ConversionError.ParseError;
            }
        },
        .optional => |opt_info| {
            if (value.len == 0) {
                return null; // Handle NULL values
            }
            return try convertField(opt_info.child, value, allocator);
        },
        else => {
            std.debug.print("Unsupported field type: {}\n", .{FieldType});
            return ConversionError.UnsupportedType;
        },
    }
}

/// Frees memory allocated for converted structs
/// T: The struct type
/// allocator: The allocator used to create the structs
/// structs: The array of structs to free
pub fn freeConvertedResult(comptime T: type, allocator: Allocator, structs: []T) void {
    // const type_info = @typeInfo(T);
    const fields = std.meta.fields(T);
    // Free string fields in each struct
    for (structs) |item| {
        inline for (fields) |field| {
            const field_type_info = @typeInfo(field.type);
            switch (field_type_info) {
                .pointer => |ptr_info| {
                    if (ptr_info.child == u8 and ptr_info.size == .slice) {
                        const field_value = @field(item, field.name);
                        if (field_value.len > 0) {
                            allocator.free(field_value);
                        }
                    }
                },
                .optional => |opt_info| {
                    const opt_type_info = @typeInfo(opt_info.child);
                    if (opt_type_info == .pointer) {
                        if (opt_type_info.pointer.child == u8 and opt_type_info.pointer.size == .slice) {
                            const field_value = @field(item, field.name);
                            if (field_value) |str| {
                                if (str.len > 0) {
                                    allocator.free(str);
                                }
                            }
                        }
                    }
                },
                else => {}, // Non-pointer fields don't need cleanup
            }
        }
    }
    
    // Free the array itself
    allocator.free(structs);
}


//////////////////////////////////////////////
//////////////// TESTS ///////////////////////
//////////////////////////////////////////////

// Mock QueryResult structure to simulate database results
const MockQueryResult = struct {
    rows: []const []const []const u8,
};

// Test struct types
const SimpleStruct = struct {
    id: i32,
    name: []const u8,
    active: bool,
};

const ComplexStruct = struct {
    id: i64,
    name: []const u8,
    score: f64,
    count: u32,
    enabled: bool,
    description: ?[]const u8,
    rating: ?f32,
    flag: ?bool,
};

const NumericStruct = struct {
    int8_field: i8,
    int16_field: i16,
    int32_field: i32,
    int64_field: i64,
    uint8_field: u8,
    uint16_field: u16,
    uint32_field: u32,
    uint64_field: u64,
    float32_field: f32,
    float64_field: f64,
};

const AllOptionalStruct = struct {
    id: ?i32,
    name: ?[]const u8,
    score: ?f64,
    active: ?bool,
};

test "convertQueryResult - successful conversion with simple struct" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "1", "Alice", "true" },
        &[_][]const u8{ "2", "Bob", "false" },
        &[_][]const u8{ "3", "Charlie", "1" },
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const converted = try convertQueryResult(SimpleStruct, allocator, mock_result);
    defer freeConvertedResult(SimpleStruct, allocator, converted);
    
    try testing.expect(converted.len == 3);
    
    try testing.expect(converted[0].id == 1);
    try testing.expectEqualStrings("Alice", converted[0].name);
    try testing.expect(converted[0].active == true);
    
    try testing.expect(converted[1].id == 2);
    try testing.expectEqualStrings("Bob", converted[1].name);
    try testing.expect(converted[1].active == false);
    
    try testing.expect(converted[2].id == 3);
    try testing.expectEqualStrings("Charlie", converted[2].name);
    try testing.expect(converted[2].active == true);
}

test "convertQueryResult - complex struct with optionals" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "100", "Product A", "95.5", "50", "true", "Best product", "4.8", "1" },
        &[_][]const u8{ "200", "Product B", "87.2", "25", "false", "", "", "0" },
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const converted = try convertQueryResult(ComplexStruct, allocator, mock_result);
    defer freeConvertedResult(ComplexStruct, allocator, converted);
    
    try testing.expect(converted.len == 2);
    
    // First row - all fields populated
    try testing.expect(converted[0].id == 100);
    try testing.expectEqualStrings("Product A", converted[0].name);
    try testing.expect(converted[0].score == 95.5);
    try testing.expect(converted[0].count == 50);
    try testing.expect(converted[0].enabled == true);
    try testing.expect(converted[0].description != null);
    try testing.expectEqualStrings("Best product", converted[0].description.?);
    try testing.expect(converted[0].rating != null);
    try testing.expectApproxEqRel(converted[0].rating.?, 4.8, 0.001);
    try testing.expect(converted[0].flag != null);
    try testing.expect(converted[0].flag.? == true);
    
    // Second row - some empty fields
    try testing.expect(converted[1].id == 200);
    try testing.expectEqualStrings("Product B", converted[1].name);
    try testing.expect(converted[1].score == 87.2);
    try testing.expect(converted[1].count == 25);
    try testing.expect(converted[1].enabled == false);
    try testing.expect(converted[1].description == null);
    try testing.expect(converted[1].rating == null);
    try testing.expect(converted[1].flag != null);
    try testing.expect(converted[1].flag.? == false);
}

test "convertQueryResult - all numeric types" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "127", "32767", "2147483647", "9223372036854775807", "255", "65535", "4294967295", "18446744073709551615", "3.14", "2.718281828" },
        &[_][]const u8{ "-128", "-32768", "-2147483648", "-9223372036854775808", "0", "0", "0", "0", "-1.5", "-10.25" },
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const converted = try convertQueryResult(NumericStruct, allocator, mock_result);
    defer freeConvertedResult(NumericStruct, allocator, converted);
    
    try testing.expect(converted.len == 2);
    
    // First row - max values
    try testing.expect(converted[0].int8_field == 127);
    try testing.expect(converted[0].int16_field == 32767);
    try testing.expect(converted[0].int32_field == 2147483647);
    try testing.expect(converted[0].int64_field == 9223372036854775807);
    try testing.expect(converted[0].uint8_field == 255);
    try testing.expect(converted[0].uint16_field == 65535);
    try testing.expect(converted[0].uint32_field == 4294967295);
    try testing.expect(converted[0].uint64_field == 18446744073709551615);
    try testing.expectApproxEqRel(converted[0].float32_field, 3.14, 0.001);
    try testing.expectApproxEqRel(converted[0].float64_field, 2.718281828, 0.000001);
    
    // Second row - min/zero values
    try testing.expect(converted[0].int8_field == 127);
    try testing.expect(converted[1].int8_field == -128);
    try testing.expect(converted[1].int16_field == -32768);
    try testing.expect(converted[1].int32_field == -2147483648);
    try testing.expect(converted[1].int64_field == -9223372036854775808);
    try testing.expect(converted[1].uint8_field == 0);
    try testing.expect(converted[1].uint16_field == 0);
    try testing.expect(converted[1].uint32_field == 0);
    try testing.expect(converted[1].uint64_field == 0);
    try testing.expectApproxEqRel(converted[1].float32_field, -1.5, 0.001);
    try testing.expectApproxEqRel(converted[1].float64_field, -10.25, 0.001);
}

test "convertQueryResult - boolean variations" {
    const allocator = testing.allocator;
    
    const BoolStruct = struct {
        b1: bool,
        b2: bool,
        b3: bool,
        b4: bool,
        b5: bool,
        b6: bool,
        b7: bool,
        b8: bool,
    };
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "true", "TRUE", "1", "yes", "false", "FALSE", "0", "no" },
        &[_][]const u8{ "on", "ON", "True", "Yes", "off", "OFF", "False", "No" },
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const converted = try convertQueryResult(BoolStruct, allocator, mock_result);
    defer freeConvertedResult(BoolStruct, allocator, converted);
    
    try testing.expect(converted.len == 2);
    
    // First row
    try testing.expect(converted[0].b1 == true);
    try testing.expect(converted[0].b2 == true);
    try testing.expect(converted[0].b3 == true);
    try testing.expect(converted[0].b4 == true);
    try testing.expect(converted[0].b5 == false);
    try testing.expect(converted[0].b6 == false);
    try testing.expect(converted[0].b7 == false);
    try testing.expect(converted[0].b8 == false);
    
    // Second row
    try testing.expect(converted[1].b1 == true);
    try testing.expect(converted[1].b2 == true);
    try testing.expect(converted[1].b3 == true);
    try testing.expect(converted[1].b4 == true);
    try testing.expect(converted[1].b5 == false);
    try testing.expect(converted[1].b6 == false);
    try testing.expect(converted[1].b7 == false);
    try testing.expect(converted[1].b8 == false);
}

test "convertQueryResult - empty values and optionals" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "", "", "", "" },
        &[_][]const u8{ "42", "test", "3.14", "true" },
    };
    
    const mock_result = MockQueryResult{ .rows = &rows };
    
    const converted = try convertQueryResult(AllOptionalStruct, allocator, mock_result);
    defer freeConvertedResult(AllOptionalStruct, allocator, converted);
    
    try testing.expect(converted.len == 2);
    
    // First row - all null/empty
    try testing.expect(converted[0].id == null);
    try testing.expect(converted[0].name == null);
    try testing.expect(converted[0].score == null);
    try testing.expect(converted[0].active == null);
    
    // Second row - all populated
    try testing.expect(converted[1].id != null);
    try testing.expect(converted[1].id.? == 42);
    try testing.expect(converted[1].name != null);
    try testing.expectEqualStrings("test", converted[1].name.?);
    try testing.expect(converted[1].score != null);
    try testing.expectApproxEqRel(converted[1].score.?, 3.14, 0.001);
    try testing.expect(converted[1].active != null);
    try testing.expect(converted[1].active.? == true);
}

test "convertQueryResult - empty rows" {
    const allocator = testing.allocator;
    
    const rows: [][]const []const u8 = &[_][]const []const u8{};
    const mock_result = MockQueryResult{ .rows = rows };
    
    const converted = try convertQueryResult(SimpleStruct, allocator, mock_result);
    defer freeConvertedResult(SimpleStruct, allocator, converted);
    
    try testing.expect(converted.len == 0);
}

test "convertQueryResult - field count mismatch error" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "1", "Alice" }, // Missing third field
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const result = convertQueryResult(SimpleStruct, allocator, mock_result);
    try testing.expectError(ConversionError.InvalidFieldCount, result);
}

test "convertQueryResult - integer parse error" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "not_a_number", "Alice", "true" },
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const result = convertQueryResult(SimpleStruct, allocator, mock_result);
    try testing.expectError(ConversionError.ParseError, result);
}

test "convertQueryResult - float parse error" {
    const allocator = testing.allocator;
    
    const FloatStruct = struct {
        value: f64,
    };
    
    const rows = [_][]const []const u8{
        &[_][]const u8{"not_a_float"},
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const result = convertQueryResult(FloatStruct, allocator, mock_result);
    try testing.expectError(ConversionError.ParseError, result);
}

test "convertQueryResult - boolean parse error" {
    const allocator = testing.allocator;
    
    const BoolStruct = struct {
        flag: bool,
    };
    
    const rows = [_][]const []const u8{
        &[_][]const u8{"maybe"},
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const result = convertQueryResult(BoolStruct, allocator, mock_result);
    try testing.expectError(ConversionError.ParseError, result);
}

test "convertQueryResult - unsupported type error" {
    const allocator = testing.allocator;
    
    const UnsupportedStruct = struct {
        data: []i32, // Slice of integers is not supported
    };
    
    const rows = [_][]const []const u8{
        &[_][]const u8{"123"},
    };
    
    const mock_result = MockQueryResult{ .rows = rows[0..] };
    
    const result = convertQueryResult(UnsupportedStruct, allocator, mock_result);
    try testing.expectError(ConversionError.UnsupportedType, result);
}

test "convertQueryResult - non-struct type compile error" {
    // This test verifies that the compile-time check works
    // It should fail at compile time, not runtime
    
    // Uncommenting the following lines should cause a compile error:
    // const allocator = testing.allocator;
    // const rows: [][]const []const u8 = &[_][]const []const u8{};
    // const mock_result = MockQueryResult{ .rows = rows };
    // const result = convertQueryResult(i32, allocator, mock_result);
}

test "convertField - empty values default handling" {
    const allocator = testing.allocator;
    
    // Test integer default (0)
    const int_result = try convertField(i32, "", allocator);
    try testing.expect(int_result == 0);
    
    // Test float default (0.0)
    const float_result = try convertField(f64, "", allocator);
    try testing.expect(float_result == 0.0);
    
    // Test bool default (false)
    const bool_result = try convertField(bool, "", allocator);
    try testing.expect(bool_result == false);
    
    // Test optional default (null)
    const opt_result = try convertField(?i32, "", allocator);
    try testing.expect(opt_result == null);
}

test "convertField - string duplication" {
    const allocator = testing.allocator;
    
    const original = "test string";
    const result = try convertField([]const u8, original, allocator);
    defer allocator.free(result);
    
    try testing.expectEqualStrings(original, result);
    // Verify it's a different memory location (duplication worked)
    try testing.expect(result.ptr != original.ptr);
}

test "freeConvertedResult - memory cleanup" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "1", "Alice" },
        &[_][]const u8{ "2", "Bob" },
    };
    
    const StringStruct = struct {
        id: i32,
        name: []const u8,
    };
    
    const mock_result = MockQueryResult{ .rows = &rows };
    
    const converted = try convertQueryResult(StringStruct, allocator, mock_result);
    
    // This test mainly verifies that freeConvertedResult doesn't crash
    // Memory leak detection would be handled by the test runner
    freeConvertedResult(StringStruct, allocator, converted);
}

test "freeConvertedResult - with optionals" {
    const allocator = testing.allocator;
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "1", "Alice", "Bob" },
        &[_][]const u8{ "2", "", "Charlie" },
    };
    
    const OptionalStringStruct = struct {
        id: i32,
        name: ?[]const u8,
        description: []const u8,
    };
    
    const mock_result = MockQueryResult{ .rows = &rows };
    
    const converted = try convertQueryResult(OptionalStringStruct, allocator, mock_result);
    
    // Verify content before cleanup
    try testing.expect(converted[0].name != null);
    try testing.expectEqualStrings("Alice", converted[0].name.?);
    try testing.expect(converted[1].name == null);
    
    freeConvertedResult(OptionalStringStruct, allocator, converted);
}

test "integration - realistic database simulation" {
    const allocator = testing.allocator;
    
    const User = struct {
        id: i32,
        username: []const u8,
        email: []const u8,
        age: u8,
        salary: f64,
        is_active: bool,
        bio: ?[]const u8,
        rating: ?f32,
    };
    
    const rows = [_][]const []const u8{
        &[_][]const u8{ "1", "john_doe", "john@example.com", "30", "75000.50", "true", "Software engineer with 5 years experience", "4.5" },
        &[_][]const u8{ "2", "jane_smith", "jane@test.com", "25", "65000.00", "true", "", "" },
        &[_][]const u8{ "3", "bob_wilson", "bob@company.org", "45", "95000.75", "false", "Senior developer", "3.8" },
    };
    
    const mock_result = MockQueryResult{ .rows = &rows };
    
    const users = try convertQueryResult(User, allocator, mock_result);
    defer freeConvertedResult(User, allocator, users);
    
    try testing.expect(users.len == 3);
    
    // Verify first user
    try testing.expect(users[0].id == 1);
    try testing.expectEqualStrings("john_doe", users[0].username);
    try testing.expectEqualStrings("john@example.com", users[0].email);
    try testing.expect(users[0].age == 30);
    try testing.expectApproxEqRel(users[0].salary, 75000.50, 0.001);
    try testing.expect(users[0].is_active == true);
    try testing.expect(users[0].bio != null);
    try testing.expectEqualStrings("Software engineer with 5 years experience", users[0].bio.?);
    try testing.expect(users[0].rating != null);
    try testing.expectApproxEqRel(users[0].rating.?, 4.5, 0.001);
    
    // Verify second user (with null optionals)
    try testing.expect(users[1].id == 2);
    try testing.expectEqualStrings("jane_smith", users[1].username);
    try testing.expect(users[1].bio == null);
    try testing.expect(users[1].rating == null);
    
    // Verify third user
    try testing.expect(users[2].id == 3);
    try testing.expect(users[2].is_active == false);
    try testing.expect(users[2].bio != null);
    try testing.expectEqualStrings("Senior developer", users[2].bio.?);
}