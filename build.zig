const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mysql_mod = b.addModule("mysql_mod", .{
        .root_source_file = b.path("src/mysql/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    mysql_mod.addIncludePath(b.path("src/mysql/include"));
    mysql_mod.addLibraryPath(b.path("src/mysql/lib"));
    mysql_mod.linkSystemLibrary("libmysql", .{});

    const mysql_mod_unit_tests = b.addTest(.{
        .root_module = mysql_mod,
    });

    const mysql_mod_conversion_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/mysql/conversion.zig"),
    });

    const run_mysql_mod_unit_tests = b.addRunArtifact(mysql_mod_unit_tests);
    const run_mysql_mod_conversion_unit_tests = b.addRunArtifact(mysql_mod_conversion_unit_tests);

    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_mysql_mod_unit_tests.step);
    test_step.dependOn(&run_mysql_mod_conversion_unit_tests.step);
}
