module nir;

import std::io::file;

DynamicArenaAllocator arena @private;

fn NirBuilder* create_builder() {
    arena.init(mem, 64 * 1024);
    Allocator alloc = &arena;

    NirBuilder* builder = alloc::new(alloc, NirBuilder);
    builder.alloc            = alloc;
    builder.mod              = alloc::new(alloc, NirModule);
    builder.current_function = null;
    builder.mod.statements.init(alloc);

    return builder;
}

fn NirStatement* build_function(NirBuilder* builder, NirType type, NirParameter[] parameters, String name) {
    return @make_stmt(builder, NirStatementKind.FUNCTION; stmt) {
        stmt.func_stmt.type = type;
        stmt.func_stmt.name = name;
        stmt.func_stmt.parameters.init(builder.alloc);
        stmt.func_stmt.statements.init(builder.alloc);

        foreach (NirParameter parameter : parameters) {
            stmt.func_stmt.parameters.push(parameter);
            stmt.func_stmt.statements.push(@make_stmt(builder, NirStatementKind.RESERVE; res) {
                res.reserve_stmt.type = parameter.type;
                res.reserve_stmt.name = parameter.name;
            });
        }

        builder.mod.statements.push(stmt);
        builder.current_function = stmt;
    };
}

fn NirStatement* build_extern(NirBuilder* builder, NirType type, NirParameter[] parameters, String name) {
    return @make_stmt(builder, NirStatementKind.EXTERN; stmt) {
        stmt.func_stmt.type = type;
        stmt.func_stmt.name = name;
        stmt.func_stmt.parameters.init(builder.alloc);

        foreach (NirParameter parameter : parameters) {
            stmt.func_stmt.parameters.push(parameter);
        }

        builder.mod.statements.push(stmt);
    };
}

fn void build_return(NirBuilder* builder, NirValue* value) {
    @make_stmt(builder, NirStatementKind.RETURN; stmt) {
        stmt.return_stmt.value = value;

        builder.current_function.func_stmt.statements.push(stmt);
    };
}

fn NirValue* build_int(NirBuilder* builder, NirType type, int value) {
    return @make_value(builder, NirValueKind.INT; val) {
        val.integer.type  = type;
        val.integer.value = value;
    };
}

fn NirStatement* get_param(NirStatement* function, int index) {
    return function.func_stmt.statements.get(index);
}


fn void add_attributes(NirStatement* statement, NirAttribute[] attributes) {
    statement.attributes.push_all(attributes);
}


fn void emit_nir(NirModule* mod, String filename) => @pool() {
    DString out;
    out.tinit();

    ir::emit_module(&out, mod);
    file::save(filename, out.str_view())!!;
}

fn void emit_obj(NirModule* mod, String filename) => @pool() {
    // File out = file::open(filename, "wb")!!;

    // elf64::emit_module(&out, mod);

    // out.close()!!;
}


macro @make_stmt(NirBuilder* builder, NirStatementKind kind; @body(NirStatement* stmt)) {
    NirStatement* statement = alloc::new(builder.alloc, NirStatement);
    statement.kind = kind;
    statement.attributes.init(builder.alloc);

    @body(statement);

    return statement;
}

macro @make_value(NirBuilder* builder, NirValueKind kind; @body(NirValue* val)) {
    NirValue* value = alloc::new(builder.alloc, NirValue);
    value.kind = kind;

    @body(value);

    return value;
}
