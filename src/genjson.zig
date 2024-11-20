const std = @import("std");
const winmd = @import("winmd");

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    const cmd_args = all_args[1..];
    if (cmd_args.len != 2) fatal("expected 2 cmdline arguments but got {}", .{cmd_args.len});

    const winmd_path = cmd_args[0];
    const out_dir_path = cmd_args[1];

    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{});
    defer out_dir.close();

    const winmd_content = blk: {
        var winmd_file = std.fs.cwd().openFile(winmd_path, .{}) catch |err| fatal(
            "failed to open '{s}' with {s}",
            .{ winmd_path, @errorName(err) },
        );
        defer winmd_file.close();
        break :blk try winmd_file.readToEndAlloc(arena, std.math.maxInt(usize));
    };

    var fbs = std.io.fixedBufferStream(winmd_content);
    var opt: winmd.ReadMetadataOptions = undefined;
    winmd.readMetadata(&fbs, &opt) catch |err| switch (err) {
        error.ReadMetadata => {
            std.log.err("{}", .{opt.fmtError()});
            std.process.exit(0xff);
        },
        else => |e| return e,
    };

    const string_heap: ?[]u8 = blk: {
        const strings_stream = opt.streams.strings orelse break :blk null;
        break :blk winmd_content[opt.metadata_file_offset + strings_stream.offset ..][0..strings_stream.size];
    };
    const blob_heap: ?[]u8 = blk: {
        const blobs_stream = opt.streams.blob orelse break :blk null;
        break :blk winmd_content[opt.metadata_file_offset + blobs_stream.offset ..][0..blobs_stream.size];
    };

    std.log.info("TypeDef row count is {}", .{opt.row_count.type_def});

    const tables = winmd_content[opt.table_data_file_offset..];

    var constant_map = ConstantMap.init(arena, &opt, tables) catch |e| oom(e);
    defer constant_map.deinit(arena);
    var custom_attr_map = CustomAttrMap.init(arena, &opt, tables) catch |e| oom(e);
    defer custom_attr_map.deinit(arena);

    // first scan all top-level types and sort them by namespace
    var api_map: std.StringHashMapUnmanaged(Api) = .{};

    for (0..opt.row_count.type_def) |type_def_index| {
        const row = winmd.deserializeRowAtIndex(
            .type_def,
            opt.large_columns.type_def,
            tables[opt.table_offset_type_def..],
            type_def_index,
        );

        if (false) std.log.info(
            "TypeDef {}: attr=0x{x} Name={} Namespace={} extends={} fields={} methods={}",
            .{
                type_def_index,
                row[0],
                row[1],
                row[2],
                row[3],
                row[4],
                row[5],
            },
        );
        const attributes: u32 = row[0];
        const name = winmd.getString(string_heap, row[1]) orelse fatal("invalid string index {}", .{row[1]});
        const namespace = winmd.getString(string_heap, row[2]) orelse fatal("invalid string index {}", .{row[2]});
        if (false) std.log.info("TypeDef {}: Namespace '{s}' Name '{s}' Attr=0x{x}", .{ type_def_index, namespace, name, attributes });

        if (std.mem.eql(u8, namespace, "")) {
            if (std.mem.eql(u8, name, "<Module>")) continue;

            std.log.info("TODO: handle type '{s}'", .{name});
            continue;

            // // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // // TODO: handle these types
            // if (std.mem.eql(u8, name, "_u_e__Struct") or
            //     std.mem.eql(u8, name, "_Block_e__Struct") or
            //     std.mem.eql(u8, name, "_Anonymous_e__Struct") or
            //     std.mem.eql(u8, name, "_Anonymous_e__Union") or
            //     std.mem.eql(u8, name, "_Anonymous1_e__Union") or
            //     std.mem.eql(u8, name, "_Anonymous2_e__Union") or
            //     std.mem.eql(u8, name, "_Attribute_e__Union") or
            //     std.mem.eql(u8, name, "_HeaderArm64_e__Struct") or
            //     std.mem.eql(u8, name, "_Values_e__Union") or
            //     std.mem.eql(u8, name, "_Region_e__Struct") or
            //     std.mem.eql(u8, name, "_RequestType_e__Union"))
            // {
            //     continue;
            // }
        }

        const api_name = apiFromNamespace(namespace);
        const methods = row[5];
        const entry = api_map.getOrPut(arena, api_name) catch |e| oom(e);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        const api = entry.value_ptr;

        // The "Apis" type is a specially-named type reserved to contain all the constant
        // and function declarations for an api.
        if (std.mem.eql(u8, name, "Apis")) {
            enforce(
                api.apis_type_def == null,
                "multiple 'Apis' types in the same namespace",
                .{},
            );

            api.apis_type_def = .{
                .type_def = @intCast(type_def_index),
                .fields = winmd.getTypeDefFieldRange(
                    opt.row_count.type_def,
                    opt.row_count.field,
                    opt.large_columns.type_def,
                    tables[opt.table_offset_type_def..],
                    type_def_index,
                ),
                .methods = methods,
            };
            //api.Constants = typeDef.GetFields();
            //api.Funcs = typeDef.GetMethods();
        } else {
            //TypeGenInfo typeInfo = TypeGenInfo.CreateNotNested(mr, typeDef, typeName, typeNamespace, apiNamespaceToName);
            //this.typeMap.Add(typeDefHandle, typeInfo);
            //api.AddTopLevelType(typeInfo);
            try api.type_defs.append(arena, @intCast(type_def_index));
        }
    }

    {
        var it = api_map.iterator();
        var api_index: usize = 0;
        while (it.next()) |entry| : (api_index += 1) {
            const name = entry.key_ptr.*;
            const api = entry.value_ptr;

            var basename_buf: [200]u8 = undefined;
            const basename = std.fmt.bufPrint(&basename_buf, "{s}.json", .{name}) catch @panic(
                "increase size of basename_buf",
            );

            std.log.info(
                "{}/{}: generating {s} with {} types",
                .{ api_index + 1, api_map.count(), basename, api.type_defs.items.len },
            );
            var file = try out_dir.createFile(basename, .{});
            defer file.close();
            try generateApi(
                file.writer().any(),
                &opt,
                &constant_map,
                &custom_attr_map,
                name,
                api,
                string_heap,
                blob_heap,
                tables,
            );
        }
    }
}

const shared_namespace_prefix = "Windows.Win32.";
fn apiFromNamespace(namespace: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, namespace, shared_namespace_prefix)) std.debug.panic(
        "Unexpected Namespace '{s}' (does not start with '{s}')",
        .{ namespace, shared_namespace_prefix },
    );
    return namespace[shared_namespace_prefix.len..];
}

fn enforce(cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (!cond) std.debug.panic(fmt, args);
}

const Api = struct {
    // The special "Apis" type whose fields are constants and methods are functions
    apis_type_def: ?struct {
        type_def: u32,
        fields: winmd.FieldRange,
        methods: u32,
    } = null,
    type_defs: std.ArrayListUnmanaged(u32) = .{},
};

const constant_filters_by_api = std.StaticStringMap(std.StaticStringMap(void)).initComptime(.{
    .{
        "Devices.Usb",
        std.StaticStringMap(void).initComptime(.{
            // This was marked as "duplicated" in the C# generator...is this still the case?
            .{ "WinUSB_TestGuid", {} },
        }),
    },
    .{
        "Media.MediaFoundation",
        std.StaticStringMap(void).initComptime(.{
            // It seems these values have Custom GuidAttribute's with values that don't
            // have enough bytes in their value to construct a Guid attribute
            .{ "MEDIASUBTYPE_P208", {} },
            .{ "MEDIASUBTYPE_P210", {} },
            .{ "MEDIASUBTYPE_P216", {} },
            .{ "MEDIASUBTYPE_P010", {} },
            .{ "MEDIASUBTYPE_P016", {} },
            .{ "MEDIASUBTYPE_Y210", {} },
            .{ "MEDIASUBTYPE_Y216", {} },
            .{ "MEDIASUBTYPE_P408", {} },
            .{ "MEDIASUBTYPE_P210", {} },
        }),
    },
});

// Workaround https://github.com/microsoft/win32metadata/issues/737
// These are struct types that have GUIDs but are not Com Types
const not_com_by_api = std.StaticStringMap(std.StaticStringMap(void)).initComptime(.{
    .{
        "System.Iis",
        std.StaticStringMap(void).initComptime(.{
            .{ "CONFIGURATION_ENTRY", {} },
            .{ "LOGGING_PARAMETERS", {} },
            .{ "PRE_PROCESS_PARAMETERS", {} },
            .{ "POST_PROCESS_PARAMETERS", {} },
        }),
    },
});

fn generateApi(
    writer: std.io.AnyWriter,
    opt: *const winmd.ReadMetadataOptions,
    constant_map: *const ConstantMap,
    custom_attr_map: *const CustomAttrMap,
    api_name: []const u8,
    api: *const Api,
    string_heap: ?[]const u8,
    blob_heap: ?[]const u8,
    tables: []const u8,
) !void {
    try writer.writeAll("{\r\n");

    const constant_filter = constant_filters_by_api.get(api_name) orelse std.StaticStringMap(void).initComptime(.{});

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var constants_filtered: std.StringHashMapUnmanaged(void) = .{};
    defer constants_filtered.deinit(arena);

    {
        var next_prefix: []const u8 = "\"Constants\":[";
        var next_sep: []const u8 = "";

        const range: winmd.FieldRange = if (api.apis_type_def) |t| t.fields else .{ .start = 0, .limit = 0 };
        for (range.start..range.limit) |field_index| {
            const field_row = winmd.deserializeRowAtIndex(
                .field,
                opt.large_columns.field,
                tables[opt.table_offset_field..],
                field_index,
            );
            const name = winmd.getString(string_heap, field_row[1]) orelse fatal("invalid string index {}", .{field_row[1]});
            if (constant_filter.get(name)) |_| {
                std.log.info("filtering constant '{s}' (api {s})", .{ name, api_name });
                constants_filtered.put(arena, name, {}) catch |e| oom(e);
                continue;
            }
            if (false) {
                std.log.info("Constant '{s}'", .{name});
            }
            var it = custom_attr_map.getIterator(
                winmd.encodeCustomAttrParent(.field, @intCast(field_index)),
            );
            const value = try analyzeConstValue(opt, string_heap, blob_heap, tables, &it, field_row, name);

            const field_type = winmd.getBlob(blob_heap, field_row[2]) orelse fatal("invalid type signature {}", .{field_row[2]});
            if (field_type.len == 0) fatal("invalid type signature (empty)", .{});
            if (field_type[0] != 6) fatal("invalid type signature (not field 0x{x})", .{field_type[0]});
            const @"type" = field_type[1..];
            try writer.print("{s}{s}{{\r\n", .{ next_prefix, next_sep });
            next_prefix = "}";
            next_sep = ",";
            try writer.print("\t\"Name\":\"{s}\"\r\n", .{name});
            try writer.print("\t,\"Type\":{}\r\n", .{fmtTypeJson(opt, string_heap, tables, @"type")});
            switch (value) {
                .guid => |guid| {
                    try writer.print("\t,\"ValueType\":\"String\"\r\n", .{});
                    try writer.print("\t,\"Value\":\"{}\"\r\n", .{fmtGuid(guid)});
                },
                .property_key => |key| {
                    try writer.print("\t,\"ValueType\":\"PropertyKey\"\r\n", .{});
                    try writer.print(
                        "\t,\"Value\":{{\"Fmtid\":\"{}\",\"Pid\":{}}}\r\n",
                        .{ fmtGuid(key.guid), key.pid },
                    );
                },
                .default => {
                    const coded_index = winmd.encodeConstantParent(.field, @intCast(field_index));
                    const constant_index = constant_map.map.get(coded_index) orelse std.debug.panic(
                        "constant '{s}' (index {}, coded=0x{x}) has default value but no entry in constant table",
                        .{ name, field_index + 1, coded_index },
                    );
                    const constant = winmd.deserializeRowAtIndex(
                        .constant,
                        opt.large_columns.constant,
                        tables[opt.table_offset_constant..],
                        constant_index,
                    );
                    const constant_type: u8 = @intCast(0xff & constant[0]);
                    const encoded_value = winmd.getBlob(blob_heap, constant[2]) orelse @panic("constant without a value");
                    try writer.print("\t,\"ValueType\":{}\r\n", .{fmtValueTypeJson(constant_type)});
                    try writer.writeAll("\t,\"Value\":");
                    switch (winmd.ElementType.decode(constant_type) orelse @panic("invalid type byte")) {
                        // .void => try writer.writeAll("\"Void\""),
                        // .boolean => try writer.writeAll("\"Boolean\""),
                        // .char => try writer.writeAll("\"Char\""),
                        // .i1 => try writer.writeAll("\"SByte\""),
                        .u1 => try writeConstValue(writer, u8, encoded_value),
                        // .i2 => try writeConstValue(writer, i16, encoded_value),
                        .u2 => try writeConstValue(writer, u16, encoded_value),
                        .i4 => try writeConstValue(writer, i32, encoded_value),
                        .u4 => try writeConstValue(writer, u32, encoded_value),
                        .i8 => try writeConstValue(writer, i64, encoded_value),
                        .u8 => try writeConstValue(writer, u64, encoded_value),
                        .r4 => try writeConstValue(writer, f32, encoded_value),
                        .r8 => try writeConstValue(writer, f64, encoded_value),
                        .string => {
                            if (encoded_value.len == 0) {
                                try writer.writeAll("null");
                            } else {
                                try writer.writeAll("\"");
                                const ptr: [*]align(1) const u16 = @alignCast(@ptrCast(encoded_value.ptr));
                                const slice_u16 = ptr[0..@divTrunc(encoded_value.len, 2)];
                                for (slice_u16) |c| {
                                    const one_char = [_]u16{c};
                                    switch (c) {
                                        0x00,
                                        0x0f,
                                        0x10,
                                        0x1e,
                                        => try writer.print("\\u{x:0>4}", .{c}),
                                        '\n' => try writer.writeAll("\\n"),
                                        '\\' => try writer.writeAll("\\\\"),
                                        else => try writer.print("{}", .{std.unicode.fmtUtf16Le(&one_char)}),
                                    }
                                }
                                try writer.writeAll("\"");
                            }
                        },
                        else => |n| std.debug.panic("unhandled element type {s}", .{@tagName(n)}),
                    }
                    try writer.writeAll("\r\n");
                },
            }
            try writer.print("\t,\"Attrs\":[]\r\n", .{});
        }
        try writer.print("{s}],\r\n\r\n", .{next_prefix});
    }

    for (constant_filter.keys()) |key| {
        if (null == constants_filtered.get(key)) {
            std.log.err("constant filter api '{s}' name '{s}' was not applied", .{ api_name, key });
            std.process.exit(0xff);
        }
    }

    {
        const not_com_map = not_com_by_api.get(api_name) orelse std.StaticStringMap(void).initComptime(.{});

        var not_com_applied: std.StringHashMapUnmanaged(void) = .{};
        defer not_com_applied.deinit(arena);

        var next_prefix: []const u8 = "\"Types\":[";
        var next_sep: []const u8 = "";
        for (api.type_defs.items) |type_def_index| {
            try writer.print("{s}{s}{{\r\n", .{ next_prefix, next_sep });
            next_prefix = "}";
            next_sep = ",";
            try generateType(
                arena,
                writer,
                opt,
                string_heap,
                blob_heap,
                tables,
                constant_map,
                custom_attr_map,
                &not_com_map,
                &not_com_applied,
                type_def_index,
            );
        }
        try writer.print("{s}],\r\n\r\n", .{next_prefix});

        for (not_com_map.keys()) |key| {
            if (null == not_com_applied.get(key)) {
                std.log.err("not com api '{s}' name '{s}' was not applied", .{ api_name, key });
                std.process.exit(0xff);
            }
        }
    }
    try writer.writeAll("\"Functions\":[\r\n");
    try writer.writeAll("    \"TODO: generate functions\"\r\n");
    try writer.writeAll("]\r\n\r\n,\"UnicodeAliases\":[\r\n");
    try writer.writeAll("    \"TODO: generate unicode aliases\"\r\n");
    try writer.writeAll("]\r\n\r\n}\r\n");
}

fn generateType(
    arena: std.mem.Allocator,
    writer: std.io.AnyWriter,
    opt: *const winmd.ReadMetadataOptions,
    string_heap: ?[]const u8,
    blob_heap: ?[]const u8,
    tables: []const u8,
    constant_map: *const ConstantMap,
    custom_attr_map: *const CustomAttrMap,
    not_com_map: *const std.StaticStringMap(void),
    not_com_applied: *std.StringHashMapUnmanaged(void),
    type_def_index: u32,
) !void {
    const type_def = winmd.deserializeRowAtIndex(
        .type_def,
        opt.large_columns.type_def,
        tables[opt.table_offset_type_def..],
        type_def_index,
    );
    const name = winmd.getString(string_heap, type_def[1]) orelse @panic("type missing name");
    try writer.print("\t\"Name\":\"{s}\"\r\n", .{name});

    var attrs: TypeAttrs = .{
        .flags = @bitCast(type_def[0]),
    };
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //std.log.info("Type '{s}' Flags 0x{x} {}", .{ name, type_def[2], attrs.flags });
    //std.debug.assert(!attrs.flags.reserved0);
    //std.debug.assert(!attrs.flags.reserved1);
    //std.debug.assert(0 == attrs.flags.reserved2);
    //std.debug.assert(0 == attrs.flags.reserved3);
    //std.debug.assert(0 == attrs.flags.reserved4);

    {
        var it = custom_attr_map.getIterator(
            winmd.encodeCustomAttrParent(.type_def, @intCast(type_def_index)),
        );
        while (it.next()) |custom_attr_index| {
            const custom_attr_row = winmd.deserializeRowAtIndex(
                .custom_attr,
                opt.large_columns.custom_attr,
                tables[opt.table_offset_custom_attr..],
                custom_attr_index,
            );
            const custom_attr = CustomAttr.decode(opt, string_heap, blob_heap, tables, custom_attr_row);
            switch (custom_attr) {
                .Guid => |guid| {
                    if (attrs.guid != null) @panic("multiple guids");
                    attrs.guid = guid;
                },
                .RaiiFree => |func| {
                    if (attrs.raii_free != null) @panic("multiple RAIIFree attributes");
                    attrs.raii_free = func;
                },
                .NativeTypedef => {
                    std.debug.assert(!attrs.is_native_typedef);
                    attrs.is_native_typedef = true;
                },
                .Flags => {
                    std.debug.assert(!attrs.is_flags);
                    attrs.is_flags = true;
                },
                .UnmanagedFunctionPointer => {
                    // TODO: do something with this
                },
                .SupportedOSPlatform => |p| {
                    std.debug.assert(attrs.supported_os_platform == null);
                    attrs.supported_os_platform = p;
                },
                .SupportedArchitecture => |arches| {
                    std.debug.assert(attrs.arches == null);
                    attrs.arches = arches;
                },
                .ScopedEnum => {
                    std.debug.assert(!attrs.scoped_enum);
                    attrs.scoped_enum = true;
                },
                .InvalidHandleValue => |v| {
                    std.debug.assert(attrs.invalid_handle_value == null);
                    attrs.invalid_handle_value = v;
                },
                .Agile => {
                    std.debug.assert(!attrs.is_agile);
                    attrs.is_agile = true;
                },
                else => std.debug.panic("unexpected custom attribute '{s}' on TypeDef", .{@tagName(custom_attr)}),
            }
        }
    }

    try writer.writeAll("\t,\"Architectures\":[]\r\n");
    try writer.writeAll("\t,\"Platform\":null\r\n");

    const maybe_base_type_index = winmd.decodeExtends(type_def[3]);

    if (attrs.is_native_typedef) {
        attrs.verify(.{
            .scoped_enum = .no,
            .free_func = .allowed,
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            .layout = null,
            //.layout = .sequential,
            //.field_count == 1,
        });
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: verify maybe_base_type
        try writer.writeAll("\t,\"Kind\":\"NativeTypedef\"\r\n");
        try writer.writeAll("\t,\"AlsoUsableFor\":\"TODO\"\r\n");
        try writer.writeAll("\t,\"Def\":\"TODO\"\r\n");
        try writer.writeAll("\t,\"FreeFunc\":\"TODO\"\r\n");
        try writer.writeAll("\t,\"InvalidHandleValue\":\"TODO\"\r\n");
        return;
    }

    const base_type_index = maybe_base_type_index orelse {
        attrs.verify(.{
            .scoped_enum = .no,
            // TODO: TypeRefTargetKind == Com
            // TODO: layout == auto
            .free_func = .no,
            .layout = .auto,
        });
        //std.log.info("Type {s} BaseType(Table={?},Index={})", .{ name, base_type.table, base_type.index });
        return;
    };

    const base_type: enum { @"enum", value, delegate } = blk: {
        switch (base_type_index.table) {
            .type_ref => {},
            else => @panic("unexpected base type table"),
        }
        const base_type_ref = winmd.deserializeRowAtIndex(
            .type_ref,
            opt.large_columns.type_ref,
            tables[opt.table_offset_type_ref..],
            base_type_index.index,
        );
        const base_type_qn: QualifiedName = .{
            .namespace = winmd.getString(string_heap, base_type_ref[2]) orelse @panic("missing namespace"),
            .name = winmd.getString(string_heap, base_type_ref[1]) orelse @panic("missing namespace"),
        };

        if (base_type_qn.eql("System", "Enum")) break :blk .@"enum";
        if (base_type_qn.eql("System", "ValueType")) break :blk .value;
        if (base_type_qn.eql("System", "MulticastDelegate")) break :blk .delegate;
        std.debug.panic(
            "unexpected base type Namespace '{s}' Name '{s}'",
            .{ base_type_qn.namespace, base_type_qn.name },
        );
    };

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    var print_extra_stuff = true;
    switch (base_type) {
        .@"enum" => {
            attrs.verify(.{
                .scoped_enum = .allowed,
                .free_func = .no,
                .layout = .auto,
            });
            try writer.writeAll("\t,\"Kind\":\"Enum\"\r\n");
            try writer.print("\t,\"Flags\":{}\r\n", .{attrs.is_flags});
            try writer.print("\t,\"Scoped\":{}\r\n", .{attrs.scoped_enum});
            try writer.writeAll("\t,\"Values\":[\r\n");
            const int_base = try generateEnumValues(
                writer,
                opt,
                string_heap,
                blob_heap,
                tables,
                constant_map,
                type_def_index,
            );
            try writer.writeAll("\t]\r\n");
            try writer.print(
                "\t,\"IntegerBase\":{}\r\n",
                .{fmtStringJson(if (int_base) |i| @tagName(i) else null)},
            );
            print_extra_stuff = false;
        },
        .value => {
            attrs.verify(.{
                .scoped_enum = .no,
                .free_func = .no,
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // TODO: verify layout is Sequential if this is just a ComClassID
                .layout = null,
            });
            const maybe_com_guid: ?std.os.windows.GUID = blk: {
                const guid = attrs.guid orelse break :blk null;
                if (not_com_map.get(name)) |_| {
                    //std.log.info("not com '{s}' (api {s})", .{ name, api_name });
                    not_com_applied.put(arena, name, {}) catch |e| oom(e);
                    break :blk null;
                }
                break :blk guid;
            };
            if (maybe_com_guid) |com_guid| {
                _ = com_guid;
            } else {
                print_extra_stuff = false;
                try generateStruct(writer, opt, string_heap, tables, type_def_index, &attrs);
            }
        },
        .delegate => {
            attrs.verify(.{
                .scoped_enum = .no,
                .free_func = .no,
                .layout = .auto,
            });
        },
    }

    if (print_extra_stuff) {
        try writer.print("\t,\"Visibility\":\"{s}\"\r\n", .{@tagName(attrs.flags.visibility)});
        try writer.print("\t,\"Layout\":\"{s}\"\r\n", .{@tagName(attrs.flags.layout)});
        try writer.print("\t,\"Interface\":\"{}\"\r\n", .{attrs.flags.interface});
        try writer.print("\t,\"Abstract\":\"{}\"\r\n", .{attrs.flags.abstract});
        try writer.print("\t,\"Sealed\":\"{}\"\r\n", .{attrs.flags.sealed});
        try writer.print("\t,\"SpecialName\":\"{}\"\r\n", .{attrs.flags.special_name});
        try writer.print("\t,\"RTSpecialName\":\"{}\"\r\n", .{attrs.flags.rt_special_name});
        try writer.print("\t,\"Import\":\"{}\"\r\n", .{attrs.flags.import});
        try writer.print("\t,\"Serializable\":\"{}\"\r\n", .{attrs.flags.serializable});
        try writer.print("\t,\"Format\":\"{s}\"\r\n", .{@tagName(attrs.flags.format)});
        try writer.print("\t,\"HasSecurity\":{}\r\n", .{attrs.flags.has_security});
        try writer.print("\t,\"IsTypeForwarder\":{}\r\n", .{attrs.flags.is_type_forwarder});
        try writer.print("\t,\"CustomFormat\":{}\r\n", .{attrs.flags.custom_format});
        try writer.print("\t,\"BeforeFieldInit\":{}\r\n", .{attrs.flags.before_field_init});
        try writer.print(
            "\t,\"Reserved\":[{}, {}, {}, {}, {}]\r\n",
            .{ attrs.flags.reserved0, attrs.flags.reserved1, attrs.flags.reserved2, attrs.flags.reserved3, attrs.flags.reserved4 },
        );
        //try writer.print("\t,\"Attrs\":\"{any}\"\r\n", .{attrs.flags});
    }
}

fn generateStruct(
    //arena: std.mem.Allocator,
    writer: std.io.AnyWriter,
    opt: *const winmd.ReadMetadataOptions,
    string_heap: ?[]const u8,
    // blob_heap: ?[]const u8,
    tables: []const u8,
    // constant_map: *const ConstantMap,
    // custom_attr_map: *const CustomAttrMap,
    // not_com_map: *const std.StaticStringMap(void),
    // not_com_applied: *std.StringHashMapUnmanaged(void),
    type_def_index: u32,
    attrs: *const TypeAttrs,
) !void {
    const kind: []const u8 = switch (attrs.flags.layout) {
        .sequential => "Struct",
        .explicit => "Union",
        else => |l| std.debug.panic("todo: handle layout {s}", .{@tagName(l)}),
    };
    try writer.print("\t,\"Kind\":\"{s}\"\r\n", .{kind});
    try writer.print("\t,\"Size\":0\r\n", .{});
    try writer.print("\t,\"PackingSize\":0\r\n", .{});
    try writer.print("\t,\"Fields\":[\r\n", .{});
    {
        const fields = winmd.getTypeDefFieldRange(
            opt.row_count.type_def,
            opt.row_count.field,
            opt.large_columns.type_def,
            tables[opt.table_offset_type_def..],
            type_def_index,
        );
        var field_sep: []const u8 = "";
        for (fields.start..fields.limit) |field_index| {
            const field_row = winmd.deserializeRowAtIndex(
                .field,
                opt.large_columns.field,
                tables[opt.table_offset_field..],
                field_index,
            );
            const name = winmd.getString(string_heap, field_row[1]) orelse fatal("missing field name", .{});
            try writer.print("\t\t{s}{{\"Name\":\"{s}\"}}\r\n", .{ field_sep, name });
            field_sep = ",";
        }
    }
    try writer.print("\t]\r\n", .{});
}

fn fmtStringJson(s: ?[]const u8) FmtStringJson {
    return .{ .s = s };
}
const FmtStringJson = struct {
    s: ?[]const u8,
    pub fn format(
        self: FmtStringJson,
        comptime spec: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = spec;
        _ = options;
        if (self.s) |s| {
            try writer.print("\"{s}\"", .{s});
        } else {
            try writer.writeAll("null");
        }
    }
};
// const NullableOptions = struct {
//     quote: bool = false,
// };
// fn fmtNullable(comptime T: type, nullable: ?T, options: NullableOptions) FmtNullable(T) {
//     return .{ .nullable = nullable, .options = options };
// }
// fn FmtNullable(comptime T: type) type {
//     return struct {
//         nullable: ?T,
//         options: NullableOptions,

//         const Self = @This();
//         pub fn format(
//             self: Self,
//             comptime spec: []const u8,
//             options: std.fmt.FormatOptions,
//             writer: anytype,
//         ) !void {
//             _ = options;
//             if (self.nullable) |val| {
//                 const quote: []const u8 = if (self.options.quote) "\"" else "";
//                 try writer.print("{s}{" ++ spec ++ "}{s}", .{ quote, val, quote });
//             } else {
//                 try writer.writeAll("null");
//             }
//         }
//     };
// }

fn generateEnumValues(
    writer: std.io.AnyWriter,
    opt: *const winmd.ReadMetadataOptions,
    string_heap: ?[]const u8,
    blob_heap: ?[]const u8,
    tables: []const u8,
    constant_map: *const ConstantMap,
    enum_type_def_index: u32,
) !?EnumBase {
    const values = winmd.getTypeDefFieldRange(
        opt.row_count.type_def,
        opt.row_count.field,
        opt.large_columns.type_def,
        tables[opt.table_offset_type_def..],
        enum_type_def_index,
    );

    var maybe_base: ?EnumBase = null;

    var sep: []const u8 = "";
    for (values.start..values.limit) |field_index| {
        const field = winmd.deserializeRowAtIndex(
            .field,
            opt.large_columns.field,
            tables[opt.table_offset_field..],
            field_index,
        );

        const attrs: winmd.FieldAttributes = @bitCast(@as(u16, @intCast(0xffff & field[0])));
        const name = winmd.getString(string_heap, field[1]) orelse @panic("enum value missing name");

        if (attrs.eql(.{
            .access = .public,
            .special_name = true,
            .rt_special_name = true,
        })) {
            std.debug.assert(std.mem.eql(u8, name, "value__"));
            continue;
        }
        data_assert(attrs.eql(.{
            .access = .public,
            .static = true,
            .literal = true,
            .has_default = true,
        }));

        const coded_index = winmd.encodeConstantParent(.field, @intCast(field_index));
        const constant_index = constant_map.map.get(coded_index) orelse std.debug.panic(
            "constant '{s}' (index {}, coded=0x{x}) has default value but no entry in constant table",
            .{ name, field_index + 1, coded_index },
        );
        const constant = winmd.deserializeRowAtIndex(
            .constant,
            opt.large_columns.constant,
            tables[opt.table_offset_constant..],
            constant_index,
        );
        const constant_type: u8 = @intCast(0xff & constant[0]);
        const encoded_value = winmd.getBlob(blob_heap, constant[2]) orelse @panic("constant without a value");
        const base_type: EnumBase = switch (winmd.ElementType.decode(
            constant_type,
        ) orelse @panic("invalid type byte")) {
            .i1 => .SByte,
            .u1 => .Byte,
            .u2 => .UInt16,
            .i4 => .Int32,
            .u4 => .UInt32,
            .u8 => .UInt64,
            else => |t| std.debug.panic("todo: support value type '{s}'", .{@tagName(t)}),
        };
        if (maybe_base) |b| {
            std.debug.assert(b == base_type);
        } else {
            maybe_base = base_type;
        }

        // TODO: enforce there are 0 custom attributes
        try writer.print(
            "\t\t{s}{{\"Name\":\"{s}\",\"Value\":",
            .{ sep, name },
        );
        try writeEnumValue(writer, base_type, encoded_value);
        try writer.writeAll("}\r\n");
        sep = ",";
    }

    return maybe_base;
}
const EnumBase = enum {
    SByte,
    Byte,
    UInt16,
    Int32,
    UInt32,
    UInt64,
    pub fn Type(self: EnumBase) type {
        return switch (self) {
            .SByte => i8,
            .Byte => u8,
            .UInt16 => u16,
            .Int32 => i32,
            .UInt32 => u32,
            .UInt64 => u64,
        };
    }
};

fn data_assert(cond: bool) void {
    if (!cond) @panic("data assertion failed");
}

const TypeAttrs = struct {
    flags: winmd.TypeAttributes,
    guid: ?Guid = null,
    is_native_typedef: bool = false,
    is_flags: bool = false,
    raii_free: ?[]const u8 = null,
    supported_os_platform: ?[]const u8 = null,
    arches: ?u32 = null,
    scoped_enum: bool = false,
    invalid_handle_value: ?u64 = null,
    is_agile: bool = false,
    pub fn verify(self: *const TypeAttrs, o: struct {
        scoped_enum: enum { no, allowed },
        free_func: enum { no, allowed },
        layout: ?winmd.Layout,
    }) void {
        switch (o.scoped_enum) {
            .no => std.debug.assert(self.scoped_enum == false),
            .allowed => {},
        }
        switch (o.free_func) {
            .no => std.debug.assert(self.raii_free == null),
            .allowed => {},
        }
        if (o.layout) |l| std.debug.assert(l == self.flags.layout);
        // if (o.layout) |l| {
        //     if (l == self.flags.layout) {
        //         //std.log.info("Layout: MATCH {s}", .{@tagName(l)});
        //     } else {
        //         std.log.info("Layout: Mismatch expected {s} got {s}", .{ @tagName(l), @tagName(self.flags.layout) });
        //     }
        // }
    }
};

const ConstantValue = union(enum) {
    guid: Guid,
    property_key: PropertyKey,
    default: void,
};
fn analyzeConstValue(
    opt: *const winmd.ReadMetadataOptions,
    string_heap: ?[]const u8,
    blob_heap: ?[]const u8,
    tables: []const u8,
    custom_attrs: *CustomAttrMap.Iterator,
    field: [winmd.column_count.field]u32,
    name: []const u8,
) !ConstantValue {
    const attributes: winmd.FieldAttributes = @bitCast(@as(u16, @intCast(0xffff & field[0])));
    const has_value_attributes: winmd.FieldAttributes = .{
        .access = .public,
        .static = true,
        .literal = true,
        .has_default = true,
    };
    const no_value_attributes: winmd.FieldAttributes = .{
        .access = .public,
        .static = true,
    };
    const has_default_value = if (@as(u16, @bitCast(attributes)) == @as(u16, @bitCast(has_value_attributes)))
        true
    else if (@as(u16, @bitCast(attributes)) == @as(u16, @bitCast(no_value_attributes)))
        false
    else
        fatal("unexpected constant field definition attributes: {}", .{attributes});

    var maybe_guid: ?Guid = null;
    var maybe_property_key: ?PropertyKey = null;

    while (custom_attrs.next()) |custom_attr_index| {
        const custom_attr_row = winmd.deserializeRowAtIndex(
            .custom_attr,
            opt.large_columns.custom_attr,
            tables[opt.table_offset_custom_attr..],
            custom_attr_index,
        );
        const custom_attr = CustomAttr.decode(opt, string_heap, blob_heap, tables, custom_attr_row);
        switch (custom_attr) {
            .Guid => |guid| {
                if (maybe_guid != null) @panic("multiple guids");
                maybe_guid = guid;
            },
            .PropertyKey => |key| {
                if (maybe_property_key != null) @panic("multiple property keys");
                maybe_property_key = key;
            },
            else => |c| std.debug.panic("unexpected custom attribute '{s}'", .{@tagName(c)}),
        }
    }

    if (maybe_guid) |guid| {
        if (has_default_value) std.debug.panic("constant '{s}' has default value and guid", .{name});
        if (maybe_property_key != null) @panic("has guid and property key");
        return .{ .guid = guid };
    } else if (maybe_property_key) |key| {
        if (has_default_value) @panic("has default value and property  key");
        return .{ .property_key = key };
    }
    if (!has_default_value) @panic("has no default value, guid nor property key");
    return .default;
}

fn withinFixedPointRange(comptime T: type, float: T) bool {
    if (float == 0) return true;
    return @abs(float) >= 1e-4 and @abs(float) < 1.7e7;
}

fn writeEnumValue(writer: std.io.AnyWriter, base: EnumBase, bytes: []const u8) !void {
    switch (base) {
        inline else => |t| try writeConstValue(writer, t.Type(), bytes),
        //.u8 => try writeConstValue(writer, u8, bytes),
        //.u8 => try writeConstValue(writer, u8, bytes),
    }
}
fn writeConstValue(writer: anytype, comptime T: type, bytes: []const u8) !void {
    std.debug.assert(bytes.len == @sizeOf(T));
    switch (@typeInfo(T)) {
        .Int => try writer.print("{d}", .{std.mem.readInt(T, bytes[0..@sizeOf(T)], .little)}),
        .Float => {
            const Int = @Type(.{ .Int = .{ .bits = 8 * @sizeOf(T), .signedness = .unsigned } });
            const value: T = @bitCast(std.mem.readInt(Int, bytes[0..@sizeOf(T)], .little));
            if (withinFixedPointRange(T, value)) {
                try writer.print("{d}", .{value});
            } else {
                var buf: [100]u8 = undefined;
                const str = try std.fmt.bufPrint(&buf, "{e}", .{value});
                const e_index = std.mem.indexOfScalar(u8, str, 'e') orelse unreachable;
                const mantissa = str[0..e_index];
                const exp = str[e_index + 1 ..];
                const sign: []const u8 = if (exp[0] == '-') "" else "+";
                try writer.print("{s}E{s}{s:0>2}", .{ mantissa, sign, exp });
            }
        },
        else => @compileError("todo: support type " ++ @typeName(T)),
    }
}

const Guid = std.os.windows.GUID;
fn fmtGuid(guid: Guid) FmtGuid {
    return .{ .guid = guid };
}
const FmtGuid = struct {
    guid: Guid,
    pub fn format(
        self: FmtGuid,
        comptime spec: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = spec;
        _ = options;
        try writer.print(
            "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{}",
            .{
                self.guid.Data1,
                self.guid.Data2,
                self.guid.Data3,
                self.guid.Data4[0],
                self.guid.Data4[1],
                std.fmt.fmtSliceHexLower(self.guid.Data4[2..]),
            },
        );
    }
};

const PropertyKey = struct {
    guid: Guid,
    pid: u32,
};

const CustomAttr = union(enum) {
    Guid: Guid,
    PropertyKey: PropertyKey,
    NativeTypedef: void,
    Flags: void,
    RaiiFree: []const u8,
    UnmanagedFunctionPointer,
    SupportedOSPlatform: []const u8,
    SupportedArchitecture: u32,
    ScopedEnum: void,
    DoNotRelease: void,
    Reserved: void,
    InvalidHandleValue: u64,
    Agile: void,
    Const: void,
    NativeArray: struct {
        CountConst: i32,
        CountParamIndex: i16,
    },
    Obselete: struct {
        @"0": ?[]const u8,
    },
    //Todo: void,
    pub fn decode(
        opt: *const winmd.ReadMetadataOptions,
        string_heap: ?[]const u8,
        blob_heap: ?[]const u8,
        tables: []const u8,
        custom_attr_row: [3]u32,
    ) CustomAttr {
        const method = winmd.decodeCustomAttrMethod(custom_attr_row[1]);
        const method_table = method.table orelse @panic("invalid table");
        const value_blob = winmd.getBlob(blob_heap, custom_attr_row[2]) orelse @panic("CustomAttr missing value");
        if (!std.mem.startsWith(u8, value_blob, &[_]u8{ 1, 0 })) @panic("CustomAttr value unexpected prolog");
        const value = value_blob[2..];
        switch (method_table) {
            .method_def => @panic("todo"),
            .member_ref => {
                const member_ref = winmd.deserializeRowAtIndex(
                    .member_ref,
                    opt.large_columns.member_ref,
                    tables[opt.table_offset_member_ref..],
                    method.index,
                );
                const parent = winmd.decodeMemberRefParent(member_ref[0]);
                const name = winmd.getString(string_heap, member_ref[1]);
                const signature = winmd.getBlob(blob_heap, member_ref[2]) orelse @panic("possible?");
                if (signature[0] != 0x20) @panic("unexpected member_ref sig");
                const parent_table = parent.table orelse @panic("invalid member ref coded index");

                if (false) std.log.info(
                    "method member_ref row Parent=(table={s},index={}) Name='{s}' Signature={}",
                    .{ @tagName(parent_table), parent.index, name orelse "<null>", std.fmt.fmtSliceHexLower(signature) },
                );
                switch (parent_table) {
                    .type_ref => {
                        const type_ref = winmd.deserializeRowAtIndex(
                            .type_ref,
                            opt.large_columns.type_ref,
                            tables[opt.table_offset_type_ref..],
                            parent.index,
                        );
                        return decodeCustomAttr(.{
                            .namespace = winmd.getString(string_heap, type_ref[2]) orelse @panic("missing namespace"),
                            .name = winmd.getString(string_heap, type_ref[1]) orelse @panic("missing name"),
                        }, value);
                    },
                    else => @panic("todo"),
                }
            },
        }
    }
};

fn decodeCustomAttr(
    name: QualifiedName,
    value: []const u8,
) CustomAttr {
    if (name.eql("System", "FlagsAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .Flags;
    }

    if (name.eql("System.Runtime.InteropServices", "UnmanagedFunctionPointerAttribute")) {
        // NOTE: 1 fixed arg, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 1, 0, 0, 0, 0, 0 }));
        return .UnmanagedFunctionPointer;
    }

    if (name.eql("Windows.Win32.Interop", "GuidAttribute")) {
        std.debug.assert(value.len == 18);
        std.debug.assert(std.mem.eql(u8, value[16..18], &[_]u8{ 0, 0 }));
        return .{ .Guid = .{
            .Data1 = std.mem.readInt(u32, value[0..4], .little),
            .Data2 = std.mem.readInt(u16, value[4..6], .little),
            .Data3 = std.mem.readInt(u16, value[6..8], .little),
            .Data4 = value[8..16].*,
        } };
    }
    if (name.eql("Windows.Win32.Interop", "PropertyKeyAttribute")) {
        std.debug.assert(value.len == 22);
        std.debug.assert(std.mem.eql(u8, value[20..22], &[_]u8{ 0, 0 }));
        return .{ .PropertyKey = .{
            .guid = .{
                .Data1 = std.mem.readInt(u32, value[0..4], .little),
                .Data2 = std.mem.readInt(u16, value[4..6], .little),
                .Data3 = std.mem.readInt(u16, value[6..8], .little),
                .Data4 = value[8..16].*,
            },
            .pid = std.mem.readInt(u32, value[16..20], .little),
        } };
    }

    if (name.eql("Windows.Win32.Interop", "RAIIFreeAttribute")) {
        // 1 fixed arg (string), 0 named args
        const string = decodeString(value);
        std.debug.assert(std.mem.eql(u8, value[string.end..], &[_]u8{ 0, 0 }));
        return .{ .RaiiFree = string.bytes };
    }

    if (name.eql("Windows.Win32.Interop", "NativeTypedefAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .NativeTypedef;
    }

    if (name.eql("Windows.Win32.Interop", "SupportedOSPlatformAttribute")) {
        // 1 fixed arg (string), 0 named args
        const string = decodeString(value);
        std.debug.assert(std.mem.eql(u8, value[string.end..], &[_]u8{ 0, 0 }));
        return .{ .SupportedOSPlatform = string.bytes };
    }

    if (name.eql("Windows.Win32.Interop", "SupportedArchitectureAttribute")) {
        // 1 fixed arg (enum), 0 named args
        std.debug.assert(value.len == 6);
        std.debug.assert(std.mem.eql(u8, value[4..], &[_]u8{ 0, 0 }));
        return .{ .SupportedArchitecture = std.mem.readInt(u32, value[0..4], .little) };
    }

    if (name.eql("Windows.Win32.Interop", "ScopedEnumAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .ScopedEnum;
    }

    if (name.eql("Windows.Win32.Interop", "DoNotReleaseAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .DoNotRelease;
    }

    if (name.eql("Windows.Win32.Interop", "ReservedAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .Reserved;
    }

    if (name.eql("Windows.Win32.Interop", "InvalidHandleValueAttribute")) {
        // 1 fixed arg (u64), 0 named args
        std.debug.assert(value.len == 10);
        std.debug.assert(std.mem.eql(u8, value[8..], &[_]u8{ 0, 0 }));
        return .{ .InvalidHandleValue = std.mem.readInt(u64, value[0..8], .little) };
    }

    if (name.eql("Windows.Win32.Interop", "AgileAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .Agile;
    }

    std.debug.panic(
        "TODO: decode CustomAttr Namespace='{s}' Name='{s}' Value({} bytes)={}",
        .{
            name.namespace,
            name.name,
            value.len,
            std.fmt.fmtSliceHexLower(value),
        },
    );
}

fn decodeString(value: []const u8) struct { bytes: []const u8, end: usize } {
    std.debug.assert(value.len >= 1);
    const unsigned_len: usize = @intFromEnum(winmd.decodeSigUnsignedLen(value[0]));
    const string_len = winmd.decodeSigUnsigned(value[0..unsigned_len]);
    const remaining = value[unsigned_len..];
    std.debug.assert(remaining.len >= string_len);
    return .{ .bytes = remaining[0..string_len], .end = unsigned_len + string_len };
}

const QualifiedName = struct {
    namespace: []const u8,
    name: []const u8,
    pub fn eql(self: QualifiedName, namespace: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, self.namespace, namespace) and
            std.mem.eql(u8, self.name, name);
    }
};

const CustomAttrArgs = struct {
    pub fn enforceFixedArgCount(self: *const CustomAttrArgs, count: u32) void {
        _ = self;
        _ = count;
        @panic("todo");
    }
    pub fn enforceNamedArgCount(self: *const CustomAttrArgs, count: u32) void {
        _ = self;
        _ = count;
        @panic("todo");
    }
};

fn fmtTypeJson(
    opt: *const winmd.ReadMetadataOptions,
    string_heap: ?[]const u8,
    tables: []const u8,
    sig: []const u8,
) FmtTypeJson {
    return .{
        .opt = opt,
        .string_heap = string_heap,
        .tables = tables,
        .sig = sig,
    };
}
const FmtTypeJson = struct {
    opt: *const winmd.ReadMetadataOptions,
    string_heap: ?[]const u8,
    tables: []const u8,
    sig: []const u8,
    pub fn format(
        self: FmtTypeJson,
        comptime spec: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = spec;
        _ = options;
        writeTypeJson(
            writer,
            self.opt,
            self.string_heap,
            self.tables,
            self.sig,
        ) catch |err| switch (err) {
            error.SigTruncated, error.InvalidSig => std.debug.panic(
                "invalid signature 0x{}",
                .{std.fmt.fmtSliceHexLower(self.sig)},
            ),
            else => |e| return e,
        };
    }
};

fn writeNative(writer: anytype, name: []const u8) !void {
    try writer.print("{{\"Kind\":\"Native\",\"Name\":\"{s}\"}}", .{name});
}

const TypeRefKind = enum { Default, FunctionPointer, Com };
fn writeApiRef(writer: anytype, args: struct {
    name: []const u8,
    target_kind: TypeRefKind,
    api: []const u8,
    parents: []const []const u8,
}) !void {
    if (args.parents.len > 0) @panic("todo");
    try writer.print(
        "{{\"Kind\":\"ApiRef\",\"Name\":\"{s}\",\"TargetKind\":\"{s}\",\"Api\":\"{s}\",\"Parents\":[]}}",
        .{ args.name, @tagName(args.target_kind), args.api },
    );
}

fn writeTypeJson(
    writer: anytype,
    opt: *const winmd.ReadMetadataOptions,
    string_heap: ?[]const u8,
    tables: []const u8,
    sig: []const u8,
) !void {
    if (sig.len == 0) return error.SigTruncated;

    switch (winmd.ElementType.decode(sig[0]) orelse return error.InvalidSig) {
        .end => @panic("todo"),
        .void => try writeNative(writer, "Void"),
        .boolean => try writeNative(writer, "Boolean"),
        .char => try writeNative(writer, "Char"),
        .i1 => try writeNative(writer, "SByte"),
        .u1 => try writeNative(writer, "Byte"),
        .i2 => try writeNative(writer, "Int16"),
        .u2 => try writeNative(writer, "UInt16"),
        .i4 => try writeNative(writer, "Int32"),
        .u4 => try writeNative(writer, "UInt32"),
        .i8 => try writeNative(writer, "Int64"),
        .u8 => try writeNative(writer, "UInt64"),
        .r4 => try writeNative(writer, "Single"),
        .r8 => try writeNative(writer, "Double"),
        .string => try writeNative(writer, "String"),
        .ptr => @panic("todo"),
        .byref => @panic("todo"),
        .valuetype => {
            const token_bytes = sig[1..];
            if (token_bytes.len == 0) @panic("truncated");
            const len = winmd.decodeSigUnsignedLen(token_bytes[0]);
            if (token_bytes.len != @intFromEnum(len)) @panic("?");
            const token_encoded = winmd.decodeSigUnsigned(token_bytes);
            const token = winmd.decodeTypeToken(token_encoded);
            const table = token.table orelse @panic("invalid table");
            switch (table) {
                .type_def => @panic("todo(type_def)"),
                .type_ref => {
                    const type_ref = winmd.deserializeRowAtIndex(
                        .type_ref,
                        opt.large_columns.type_ref,
                        tables[opt.table_offset_type_ref..],
                        token.index,
                    );
                    //const res_scope = winmd.decodeResolutionScope(type_ref[0]);
                    const name = winmd.getString(string_heap, type_ref[1]) orelse @panic("missing type name");
                    const namespace = winmd.getString(string_heap, type_ref[2]) orelse @panic("type not in expected namespace");
                    if (std.mem.eql(u8, namespace, "System")) {
                        if (std.mem.eql(u8, name, "Guid")) {
                            try writeNative(writer, "Guid");
                            return;
                        }
                        @panic("todo");
                    }
                    if (!std.mem.startsWith(u8, namespace, shared_namespace_prefix)) std.debug.panic(
                        "Unexpected Namespace '{s}' (does not start with '{s}') for type '{s}'",
                        .{ namespace, shared_namespace_prefix, name },
                    );

                    try writeApiRef(writer, .{
                        .name = name,
                        // TODO:
                        .target_kind = .Default,
                        .api = apiFromNamespace(namespace),
                        // TODO:
                        .parents = &.{},
                    });
                },
                .type_spec => @panic("invalid table"),
            }
        },
        .class => @panic("todo"),
        .@"var" => @panic("todo"),
        .array => @panic("todo"),
        .genericinst => @panic("todo"),
        .typed_byref => @panic("todo"),
        .intptr => @panic("todo"),
        .uintptr => @panic("todo"),
        .fnptr => @panic("todo"),
        .object => @panic("todo"),
        .szarray => @panic("todo"),
        .mvar => @panic("todo"),
    }
    // switch (SigType.decode(sig[0]) orelse return error.InvalidSig) {
    //     .ptr => {
    //         try writer.writeAll("{\"Kind\":\"PointerTo\",\"Child\":");
    //         try writeTypeJson(writer, opt, string_heap, tables, sig[1..]);
    //         try writer.writeByte('}');
    //     },
    //     .class => {
}

fn fmtValueTypeJson(@"type": u8) FmtValueTypeJson {
    return .{ .type = @"type" };
}
const FmtValueTypeJson = struct {
    type: u8,
    pub fn format(
        self: FmtValueTypeJson,
        comptime spec: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = spec;
        _ = options;
        switch (winmd.ElementType.decode(self.type) orelse @panic("invalid type byte")) {
            //.void => try writer.writeAll("\"Void\""),
            // .boolean => try writer.writeAll("\"Boolean\""),
            // .char => try writer.writeAll("\"Char\""),
            .i1 => try writer.writeAll("\"SByte\""),
            .u1 => try writer.writeAll("\"Byte\""),
            .i2 => try writer.writeAll("\"Int16\""),
            .u2 => try writer.writeAll("\"UInt16\""),
            .i4 => try writer.writeAll("\"Int32\""),
            .u4 => try writer.writeAll("\"UInt32\""),
            .i8 => try writer.writeAll("\"Int64\""),
            .u8 => try writer.writeAll("\"UInt64\""),
            .r4 => try writer.writeAll("\"Single\""),
            .r8 => try writer.writeAll("\"Double\""),
            .string => try writer.writeAll("\"String\""),
            else => |t| std.debug.panic("todo: support value type '{s}'", .{@tagName(t)}),
        }
    }
};

// probably move to winmd.zig
pub const ConstantMap = struct {
    // maps coded indicies to constant index
    map: std.AutoHashMapUnmanaged(u32, u32),
    pub fn init(
        allocator: std.mem.Allocator,
        opt: *const winmd.ReadMetadataOptions,
        tables: []const u8,
    ) error{OutOfMemory}!ConstantMap {
        var map: std.AutoHashMapUnmanaged(u32, u32) = .{};
        errdefer map.deinit(allocator);
        const row_size = opt.large_columns.constant.rowSize(usize);
        var constant_offset: usize = opt.table_data_file_offset + @as(u64, opt.table_offset_constant);
        for (0..opt.row_count.constant) |constant| {
            const row = winmd.deserializeRowAtIndex(
                .constant,
                opt.large_columns.constant,
                tables[opt.table_offset_constant..],
                constant,
            );
            constant_offset += row_size;

            const coded_index = row[1];
            if (false) {
                const d = winmd.decodeConstantParent(coded_index);
                std.log.info(
                    "Constant {s} index {} (coded=0x{x})",
                    .{ @tagName(d.table.?), d.index, coded_index },
                );
            }

            const entry = map.getOrPut(allocator, coded_index) catch |e| oom(e);
            if (entry.found_existing) {
                @panic("multiple constants for the same entry?");
            }
            entry.value_ptr.* = @intCast(constant);
        }
        return .{ .map = map };
    }
    pub fn deinit(self: *ConstantMap, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = undefined;
    }
};
pub const CustomAttrMap = struct {
    const Node = struct {
        table_index: u32,
        next_node_index: winmd.OptionalIndex(u32),
    };
    nodes: []Node,
    map: std.AutoHashMapUnmanaged(u32, u32),
    pub fn init(
        allocator: std.mem.Allocator,
        opt: *const winmd.ReadMetadataOptions,
        tables: []const u8,
    ) error{OutOfMemory}!CustomAttrMap {
        const nodes: []Node = try allocator.alloc(Node, opt.row_count.custom_attr);
        errdefer allocator.free(nodes);
        var map: std.AutoHashMapUnmanaged(u32, u32) = .{};
        errdefer map.deinit(allocator);

        const row_size = opt.large_columns.custom_attr.rowSize(usize);
        var custom_attr_offset: usize = opt.table_data_file_offset + @as(u64, opt.table_offset_custom_attr);
        for (0..opt.row_count.custom_attr) |custom_attr| {
            const row = winmd.deserializeRowAtIndex(
                .custom_attr,
                opt.large_columns.custom_attr,
                tables[opt.table_offset_custom_attr..],
                custom_attr,
            );
            custom_attr_offset += row_size;

            const coded_index = row[0];

            const entry = map.getOrPut(allocator, coded_index) catch |e| oom(e);
            if (entry.found_existing) {
                nodes[entry.value_ptr.*].next_node_index = .{ .value = @intCast(custom_attr + 1) };
            } else {
                entry.value_ptr.* = @intCast(custom_attr);
            }
            nodes[custom_attr] = .{
                .table_index = @intCast(custom_attr),
                .next_node_index = .{ .value = 0 },
            };
        }
        return .{ .nodes = nodes, .map = map };
    }
    pub fn deinit(self: *CustomAttrMap, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        allocator.free(self.nodes);
        self.* = undefined;
    }

    pub fn getIterator(self: *const CustomAttrMap, coded_index: u32) Iterator {
        return .{
            .nodes = self.nodes,
            .next_node_index = if (self.map.get(coded_index)) |i|
                .{ .value = i + 1 }
            else
                .{ .value = 0 },
        };
    }

    pub const Iterator = struct {
        nodes: []const Node,
        next_node_index: winmd.OptionalIndex(u32),
        pub fn next(self: *Iterator) ?u32 {
            const node = &self.nodes[self.next_node_index.asIndex() orelse return null];
            self.next_node_index = node.next_node_index;
            return node.table_index;
        }
    };
};
