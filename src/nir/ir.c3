module nir::ir;

import nir::types;

import std::io;
import std::os;

fn void emit_module(DString* out, NirModule* mod) {
    foreach (NirStatement* statement : mod.statements) {
        emit_statement(out, statement, mod);
    }
}

fn void emit_statement(DString* out, NirStatement* statement, NirModule* mod) {
    switch (statement.kind) {
    case NirStatementKind.FUNCTION: emit_function(out, statement, mod);
    case NirStatementKind.RETURN:   emit_return(out, statement);
    default:
        io::eprintfn("missing nir::ir emit case for kind '%s'", statement.kind);
        os::exit(1);
    }
}

fn void emit_function(DString* out, NirStatement* statement, NirModule* mod) {
    out.append("prog ");
    out.append(statement.func_stmt.name);
    out.append(" ");

    emit_type(out, statement.func_stmt.type);
    emit_parameters(out, statement.func_stmt.parameters);
    emit_attributes(out, statement.attributes);

    out.appendfn(":");

    foreach (NirStatement* stmt : statement.func_stmt.statements) {
        emit_statement(out, stmt, mod);
    }

    out.appendfn("");
}

fn void emit_return(DString* out, NirStatement* statement) {
    out.append("    ret ");

    emit_value(out, statement.return_stmt.value);

    out.appendfn("");
}

fn void emit_int(DString* out, NirValue* value) {
    out.appendf("%d", value.integer.value);
    out.append(" ");

    emit_type(out, value.integer.type);
}


fn void emit_type(DString* out, NirType type) {
    out.append(type.name);
}

fn void emit_value(DString* out, NirValue* value) {
    switch (value.kind) {
    case NirValueKind.INT: emit_int(out, value);
    default:
        io::eprintfn("missing nir::ir emit case for kind '%s'", value.kind);
        os::exit(1);
    }
}

fn void emit_parameters(DString* out, ParameterList parameters) {
    out.append(" (");

    bool first = true;
    foreach (NirParameter parameter : parameters) {
        if (!first) {
            out.append(", ");
        } else {
            first = false;
        }

        out.append(":");
        out.append(parameter.name);
        out.append(" ");

        emit_type(out, parameter.type);
    }

    out.append(")");
}

fn void emit_attributes(DString* out, AttributeList attributes) {
    foreach (NirAttribute attribute : attributes) {
        out.append(" ");
        out.append(attribute.name);
    }
}
