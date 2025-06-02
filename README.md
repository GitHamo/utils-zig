## install mysql driver

```

var driver = mysqlib.MySQLDriver.init(allocator);
defer driver.deinit();

try driver.connect(.{
    .host = "127.0.0.1",
    .username = "root",
    .password = "password",
    .database = "test",
    .port = 3306,
});

```


## use mysql driver

```
var results = try driver.execute("YOUR QUERY", null);
if (results) |*result| {
    defer result.deinit();
    for(result.rows, 0..) |row, i| {
        std.debug.print("Row {d}: {s}\n", .{i, row});
    }
}
```

## conver results into struct

```
const RowModel = struct {
    property: type,
};

var results = try driver.execute("YOUR QUERY", null);
if (results) |*result| {
    defer result.deinit();

    const rowModels = mysqlib.Converter.convertQueryResult(RowModel, allocator, result) catch |err| {
        std.debug.print("Conversion failed: {}\n", .{err});
        return;
    };
    defer mysqlib.Converter.freeConvertedResult(Endpoint, allocator, rowModels);

}
```