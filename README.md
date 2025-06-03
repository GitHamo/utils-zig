## Setup

**Prerequisites:** MySQL 8.0.1+ installed on the machine that will run the build.


## MySQL Driver: Install & Usage

```zig

// setup

var driver = mysqlib.MySQLDriver.init(allocator: std.mem.Allocator);
defer driver.deinit();

try driver.connect(.{
    .host = "127.0.0.1",
    .username = "root",
    .password = "password",
    .database = "test",
    .port = 3306,
});

// usage

// example: for results without any parameter binding
var resultsOne = try driver.execute("YOUR QUERY", null);

if (resultsOne) |*result| {
    defer result.deinit();

    // option 1: loop through results in case of select
    for(result.rows, 0..) |row, i| {
        std.debug.print("Row {d}: {s}\n", .{i, row});
    }
}


// example: for results without any parameter binding
const query_string = "SELECT col1, col2 FROM table1 WHERE col3 = ? AND col4 = ? AND col5 = ? LIMIT ?";
const select_params = [_]QueryParameter{
    QueryParameter.fromString("string"),
    QueryParameter.fromFloat(45.6),
    QueryParameter.fromNull(),
    QueryParameter.fromInt(123),
};
var resultsTwo = try driver.execute(query_string, &select_params);

const RowModel = struct {
    propertyOne: type,
    propertyTwo: type,
};

if (resultsTwo) |*result| {
    defer result.deinit();

    // option 2: convert returned results into a struct of desire
    const rowModels = mysqlib.ResultConverter.convert(RowModel, allocator, result) catch |err| {
        std.debug.print("Conversion failed: {}\n", .{err});
        return;
    };

    defer mysqlib.ResultConverter.free(Endpoint, allocator, rowModels);
}


```