module nina::lookup;

import llvm;

import nina::types;
import nina::scope;
import nina::highlighter;

import std::io;
import std::os;
import std::collections::list;

fn Lookup* create(Allocator alloc) {
    Lookup* lookup = alloc::new(alloc, Lookup);

    lookup.init(alloc);

    register_type(lookup, alloc, "int",    "<builtin>", null, llvm::int_32_type());
    register_type(lookup, alloc, "bool",   "<builtin>", null, llvm::int_1_type());
    register_type(lookup, alloc, "char",   "<builtin>", null, llvm::int_8_type());
    register_type(lookup, alloc, "long",   "<builtin>", null, llvm::int_64_type());
    register_type(lookup, alloc, "real",   "<builtin>", null, llvm::double_type());
    register_type(lookup, alloc, "void",   "<builtin>", null, llvm::void_type());
    register_type(lookup, alloc, "String", "<builtin>", null, llvm::slice_type(llvm::int_8_type()));

    return lookup;
}

fn void register_type(Lookup* lookup, Allocator alloc, String name, String filepath, Node* node, LLVMTypeRef llvm_type) {
    Type* type = alloc::new(alloc, Type);

    type.name      = name;
    type.filepath  = filepath;
    type.node      = node;
    type.llvm_type = llvm_type;

    lookup.set(name, type);
}

fn LLVMTypeRef get_llvm_type(CompileContext* context, Node* node, Scope* scope) {
    switch (node.type) {
    case NodeType.TYPE:
        String type_name   = node.type_node.name.ident_node.name;
        String type_suffix = node.type_node.suffix;

        TypeInfo*   type_info = get_type_info(context, type_name);
        LLVMTypeRef llvm_type = type_info.llvm_type;

        while (type_suffix.ends_with("*") || type_suffix.ends_with("[]")) {
            switch (type_suffix[type_suffix.len - 1]) {
            case '*':
                type_suffix = type_suffix[:type_suffix.len - 1];
                llvm_type   = llvm::pointer_type(llvm_type, 0);
            case ']':
                type_suffix = type_suffix[:type_suffix.len - 1];
                llvm_type   = llvm::slice_type(llvm_type);
            }
        }

        if (llvm::get_type_kind(llvm_type) == LLVMTypeKind.STRUCT_TYPE_KIND && llvm::is_opaque_struct(llvm_type)) {
            List{LLVMTypeRef} llvm_fields;
            llvm_fields.tinit();
            
            foreach (Node* field : type_info.node.struct_node.fields) {
                llvm_fields.push(get_llvm_type(context, field.parameter_node.type, scope));
            }

            llvm::struct_set_body(llvm_type, llvm_fields.to_array(context.alloc), (CUInt)llvm_fields.len(), llvm::FALSE);
        }

        return llvm_type;
    case NodeType.PARAMETER:
        return get_llvm_type(context, node.parameter_node.type, scope);
    case NodeType.VARIABLE:
        return get_llvm_type(context, node.variable_node.type, scope);
    case NodeType.REFERENCE:
        LLVMTypeRef llvm_type = get_llvm_type(context, node.reference_node.node, scope);

        return llvm::pointer_type(llvm_type, 0);
    case NodeType.IDENT:
        String name = node.ident_node.name;

        return get_llvm_type(context, scope::get_variable(scope, name).node, scope);
    case NodeType.DEREFERENCE:
        return get_pointee_llvm_type(context, node.dereference_node.node, scope);
    case NodeType.ACCESS:
        String        name          = node.access_node.name.path_node.path;
        VariableInfo* variable_info = scope::get_variable(scope, name);
        String        base_group    = get_base_type_group(context, variable_info.node, scope);

        String type_name = get_type_name(context, variable_info.node, scope);

        if (base_group == "pointer") {
            type_name = type_name[:type_name.len - 1];
        }

        TypeInfo* type_info = get_type_info(context, type_name);
        NodeList  fields     = get_type_fields(context, type_info, scope);
        String    field_name = node.access_node.next.ident_node.name;

        Node* field_node;
        foreach (Node* field : fields) {
            if (field.parameter_node.name.ident_node.name == field_name) {
                field_node = field;
                break;
            }
        }

        return get_llvm_type(context, field_node.parameter_node.type, scope);
    case NodeType.BIN:
        return get_llvm_type(context, node.bin_node.left, scope);
    default:
        highlighter::panic("Missing get_llvm_type case for type '%s'", node.type);
    }
}

fn LLVMTypeRef get_pointee_llvm_type(CompileContext* context, Node* node, Scope* scope) {
    Node* inner = node;

    while (inner.type == NodeType.IDENT) {
        inner = scope::get_variable(scope, inner.ident_node.name).node;
    }

    if (inner.type == NodeType.VARIABLE) {
        inner = inner.variable_node.type;
    } else if (inner.type == NodeType.PARAMETER) {
        inner = inner.parameter_node.type;
    } else if (inner.type == NodeType.ACCESS) {
        String        access_name     = inner.access_node.name.path_node.path;
        VariableInfo* access_var_info = scope::get_variable(scope, access_name);
        String        access_group    = get_base_type_group(context, access_var_info.node, scope);
        String        type_name       = get_type_name(context, access_var_info.node, scope);

        if (access_group == "pointer") {
            type_name = type_name[:type_name.len - 1];
        }

        TypeInfo* type_info  = get_type_info(context, type_name);
        NodeList  fields      = get_type_fields(context, type_info, scope);
        String    field_name  = inner.access_node.next.ident_node.name;

        foreach (Node* field : fields) {
            if (field.parameter_node.name.ident_node.name == field_name) {
                inner = field.parameter_node.type;
                break;
            }
        }
    } else if (inner.type == NodeType.BIN) {
        return get_pointee_llvm_type(context, inner.bin_node.left, scope);
    }

    Node cloned = *inner;
    cloned.type_node.suffix = cloned.type_node.suffix[:cloned.type_node.suffix.len - 1];

    return get_llvm_type(context, &cloned, scope);
}

fn LLVMMetadataRef get_llvm_debug_type(CompileContext* context, Generator* generator, Lookup* lookup, Node* node) => @pool() {
    switch (node.type) {
    case NodeType.TYPE:
        String type_name   = node.type_node.name.ident_node.name;
        String type_suffix = node.type_node.suffix;

        TypeInfo*       type_info       = get_type_info(context, type_name);
        LLVMTypeRef     llvm_type       = type_info.llvm_type; // lookup.get(type_name).llvm_type!!;
        LLVMMetadataRef llvm_debug_type = get_llvm_debug_type_from_kind(context, generator, llvm_type, type_info);

        while (type_suffix.ends_with("*") || type_suffix.ends_with("[]")) {
            switch (type_suffix[type_suffix.len - 1]) {
            case '*':
                type_suffix = type_suffix[:type_suffix.len - 1];
                llvm_type   = llvm::pointer_type(llvm_type, 0);
                llvm_debug_type = llvm::di_builder_create_pointer_type(generator.llvm_debug_builder, llvm_debug_type, 64, 0, 0, null, 0);
            case ']':
                type_suffix     = type_suffix[:type_suffix.len - 1];
                llvm_type       = llvm::slice_type(llvm_type);
                llvm_debug_type = llvm::di_builder_create_pointer_type(generator.llvm_debug_builder, llvm_debug_type, 64, 0, 0, null, 0);
            }
        }

        return llvm_debug_type;
    case NodeType.PARAMETER:
        return get_llvm_debug_type(context, generator, lookup, node.parameter_node.type);
    default:
        highlighter::panic("Missing get_llvm_debug_type case for type '%s'", node.type);
    }
}

fn LLVMMetadataRef get_llvm_debug_type_from_kind(CompileContext* context, Generator* generator, LLVMTypeRef llvm_type, TypeInfo* type_info) {
    switch (llvm::get_type_kind(llvm_type)) {
    case LLVMTypeKind.VOID_TYPE_KIND:
        return null;
    case LLVMTypeKind.INTEGER_TYPE_KIND:
        CUInt  width = llvm::get_int_type_width(llvm_type);
        String name  = string::format(context.alloc, "i%d", width);

        if (width == 1) {
            name.free(context.alloc);
            name = "bool";
        }

        return llvm::di_builder_create_basic_type(generator.llvm_debug_builder, (CChar*)name.ptr, (CUInt)name.len, width, 5, LLVMDIFlags.DI_FLAG_ZERO);
    case LLVMTypeKind.STRUCT_TYPE_KIND:
        String name = ((ZString)llvm::get_struct_name(llvm_type)).str_view().copy(context.alloc);

        uint size_in_bits = 0;
        uint align_in_bits = 0;

        List{LLVMMetadataRef} member_types;
        member_types.init(context.alloc);

        @todo("finish implementing struct members and size + align");

        return llvm::di_builder_create_struct_type(
            generator.llvm_debug_builder,
            generator.llvm_debug_file,
            (CChar*)name.ptr,
            name.len,
            generator.llvm_debug_file,
            (CUInt)type_info.node.range.from.line,
            size_in_bits,
            align_in_bits,
            LLVMDIFlags.DI_FLAG_ZERO,
            null,
            member_types.to_array(context.alloc),
            (CUInt)member_types.len(),
            0,
            null,
            (CChar*)"".ptr,
            0
        );
    default:
        highlighter::panic("Missing get_llvm_debug_type_from_kind case for type kind '%s'", llvm::get_type_kind(llvm_type));
    }
}

fn bool compare_type(CompileContext* context, Node* node, Node* other, Scope* scope) {
    String node_type  = get_type_name(context, node, scope);
    String other_type = get_type_name(context, other, scope);

    String node_base_group  = get_base_type_group(context, node, scope);
    String other_base_group = get_base_type_group(context, other, scope);

    TypeInfo* node_type_info  = get_type_info(context, node_type);
    TypeInfo* other_type_info = get_type_info(context, other_type);

    if (node_base_group == other_base_group) {
        return true;
    }

    if (node_type == other_type) {
        return true;
    }

    if (node_type_info && node_type_info == other_type_info) {
        return true;
    }

    if (node_type == "any") {
        return true;
    }

    return false;
}

fn String get_type_name(CompileContext* context, Node* node, Scope* scope) {
    switch (node.type) {
    case NodeType.PARAMETER:
        if (node.parameter_node.type) {
            return get_type_name(context, node.parameter_node.type, scope);
        }

        return "any";
    case NodeType.TYPE:
        String type_name   = node.type_node.name.path_node.path;
        String type_suffix = node.type_node.suffix;

        return string::format(context.alloc, "%s%s", type_name, type_suffix);
    case NodeType.INT:
        return "int";
    case NodeType.BOOL:
        return "bool";
    case NodeType.STRING:
        return "string";
    case NodeType.IDENT:
        String name = node.ident_node.name;

        return get_type_name(context, scope::get_variable(scope, name).node, scope);
    case NodeType.VARIABLE:
        return get_type_name(context, node.variable_node.type, scope);
    case NodeType.FUNCTION:
        return get_type_name(context, node.function_node.type, scope);
    case NodeType.BIN:
        switch (node.bin_node.operator.type) {
        case TokenType.IS_EQUAL:
        case TokenType.NOT_EQUAL:
        case TokenType.GTE:
        case TokenType.LTE:
        case TokenType.LANGLE:
        case TokenType.RANGLE:
            return "bool";
        default:
            return get_type_name(context, node.bin_node.left, scope);
        }
    case NodeType.UNARY:
        return get_type_name(context, node.unary_node.node, scope);
    case NodeType.CALL:
        String        name           = node.call_node.name.ident_node.name;
        FunctionInfo* function_info  = get_function_info(context, name);
        String        type_name      = get_type_name(context, function_info.node, scope);

        return type_name.contains(".") ? type_name : string::tformat("%s.%s", function_info.mod, type_name);
    case NodeType.ACCESS:
        Node*  path = node.access_node.name;
        String name = path.path_node.path;

        bool module_found = false;

        foreach (String mod : scope::get_imports(context.alloc, scope)) {
            if (mod == name ||
                mod.starts_with(string::tformat("%s.", name)) ||
                mod.ends_with(string::tformat(".%s", name))) {
                module_found = true;
                break;
            }
        }

        if (module_found) {
            return traverse_access_module(context, node, scope);
        } else {
            return traverse_access_variable(context, node, scope);
        }
    case NodeType.INIT:
        return node.init_node.name.path_node.path;
    case NodeType.NULL:
        return "null";
    case NodeType.RET:
        if (node.ret_node.value) {
            return get_type_name(context, node.ret_node.value, scope);
        }

        return "void";
    case NodeType.REFERENCE:
        return string::format(context.alloc, "%s*", get_type_name(context, node.reference_node.node, scope));
    case NodeType.DEREFERENCE:
        String type_name = get_type_name(context, node.dereference_node.node, scope);

        return type_name[:type_name.len - 1];
    case NodeType.REAL:
        return "real";
    default:
        highlighter::panic("Missing get_type_name case for type '%s'", node.type);
    }
}

fn String get_base_type_group(CompileContext* context, Node* node, Scope* scope) {
    switch (node.type) {
    case NodeType.PARAMETER:
        if (node.parameter_node.type) {
            return get_base_type_group(context, node.parameter_node.type, scope);
        }

        return "anytype";
    case NodeType.TYPE:
        String       type_name      = node.type_node.name.ident_node.name;
        LLVMTypeRef  llvm_type      = get_llvm_type(context, node, scope);
        LLVMTypeKind llvm_type_kind = llvm::get_type_kind(llvm_type);

        switch (llvm_type_kind) {
        case LLVMTypeKind.INTEGER_TYPE_KIND:
            CUInt width = llvm::get_int_type_width(llvm_type);

            if (width == 1) {
                return "boolean";
            }
        
            return "integer";
        case LLVMTypeKind.POINTER_TYPE_KIND:
            return "pointer";
        case LLVMTypeKind.STRUCT_TYPE_KIND:
            return "struct";
        case LLVMTypeKind.DOUBLE_TYPE_KIND:
            return "real";
        default:
            highlighter::panic("Missing get_base_type_group#TYPE case for type kind '%s'", llvm_type_kind);
        }
    case NodeType.INT:
        return "integer";
    case NodeType.BOOL:
        return "boolean";
    case NodeType.STRING:
        return "pointer";
    case NodeType.IDENT:
        String name = node.ident_node.name;

        return get_base_type_group(context, scope::get_variable(scope, name).node, scope);
    case NodeType.VARIABLE:
        return get_base_type_group(context, node.variable_node.type, scope);
    case NodeType.RET:
        if (node.ret_node.value) {
            return get_base_type_group(context, node.ret_node.value, scope);
        }

        return "void";
    case NodeType.BIN:
        switch (node.bin_node.operator.type) {
        case TokenType.IS_EQUAL:
        case TokenType.NOT_EQUAL:
        case TokenType.GTE:
        case TokenType.LTE:
        case TokenType.LANGLE:
        case TokenType.RANGLE:
            return "boolean";
        default:
            return get_base_type_group(context, node.bin_node.left, scope);
        }
    case NodeType.UNARY:
        return get_base_type_group(context, node.unary_node.node, scope);
    case NodeType.CALL:
        String        name          = node.call_node.name.ident_node.name;
        FunctionInfo* function_info = get_function_info(context, name);

        return get_base_type_group(context, function_info.node, scope);
    case NodeType.FUNCTION:
        return get_base_type_group(context, node.function_node.type, scope);
    case NodeType.ACCESS:
        Node*  path = node.access_node.name;
        String name = path.path_node.path;

        bool module_found = false;

        foreach (String mod : scope::get_imports(context.alloc, scope)) {
            if (mod == name ||
                mod.starts_with(string::tformat("%s.", name)) ||
                mod.ends_with(string::tformat(".%s", name))) {
                module_found = true;
                break;
            }
        }

        if (module_found) {
            return traverse_access_module_base_group(context, node, scope);
        } else {
            return traverse_access_variable_base_group(context, node, scope);
        }
    case NodeType.INIT:
        return node.init_node.name.path_node.path;
    case NodeType.NULL:
        return "pointer";
    case NodeType.REFERENCE:
        return "pointer";
    case NodeType.DEREFERENCE:
        LLVMTypeRef  pointee_llvm_type = get_pointee_llvm_type(context, node.dereference_node.node, scope);
        LLVMTypeKind pointee_type_kind = llvm::get_type_kind(pointee_llvm_type);

        switch (pointee_type_kind) {
        case LLVMTypeKind.INTEGER_TYPE_KIND:
            CUInt width = llvm::get_int_type_width(pointee_llvm_type);

            if (width == 1) {
                return "boolean";
            }

            return "integer";
        case LLVMTypeKind.POINTER_TYPE_KIND:
            return "pointer";
        case LLVMTypeKind.STRUCT_TYPE_KIND:
            return "struct";
        default:
            highlighter::panic("Missing get_base_type_group#DEREFERENCE case for type kind '%s'", pointee_type_kind);
        }
    case NodeType.REAL:
        return "real";
    default:
        highlighter::panic("Missing get_base_type_group case for type '%s'", node.type);
    }
}

fn NodeList get_type_fields(CompileContext* context, TypeInfo* type_info, Scope* scope) {
    switch (type_info.node.type) {
    case NodeType.STRUCT:
        return type_info.node.struct_node.fields;
    default:
        highlighter::panic();
    }
}

fn String traverse_access_variable(CompileContext* context, Node* node, Scope* scope) => @pool() {
    String        name          = node.access_node.name.path_node.path;
    VariableInfo* variable_info = scope::get_variable(scope, name);
    String        base_group    = get_base_type_group(context, variable_info.node, scope);

    String type_name = get_type_name(context, variable_info.node, scope);

    if (base_group == "pointer") {
        type_name = type_name[:type_name.len - 1];
    }

    TypeInfo* type_info = get_type_info(context, type_name);

    return traverse_access_field(context, node, scope, type_info);
}

fn String traverse_access_field(CompileContext* context, Node* node, Scope* scope, TypeInfo* type_info) => @pool() {
    String name = node.access_node.name.path_node.path;

    switch (node.access_node.next.type) {
    case NodeType.IDENT:
        break;
    default:
        highlighter::panic("traverse_access_field#access");
    }

    String   field_name = node.access_node.next.ident_node.name;
    NodeList fields     = lookup::get_type_fields(context, type_info, scope);
    String   field_type = lookup::get_type_name(context, node.access_node.name, scope);

    Node* field_node;
    foreach (Node* field : fields) {
        if (field.parameter_node.name.ident_node.name == field_name) {
            field_node = field;
            break;
        }
    }

    return get_type_name(context, field_node, scope);
}

fn String traverse_access_module(CompileContext* context, Node* node, Scope* scope) => @pool() {
    DString full_name;
    full_name.tinit();

    String function_name;

    Node* next = node;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            full_name.append(next.access_node.name.ident_node.name);
            full_name.append(".");

            next = next.access_node.next;
        case NodeType.CALL:
            full_name.append(next.call_node.name.ident_node.name);
            function_name = next.call_node.name.ident_node.name;

            next = null;
        default:
            highlighter::panic();
        }
    }

    String short_module_name = full_name.str_view().strip_suffix(string::tformat(".%s", function_name));

    String resolved_module;
    bool   found = false;

    for (Scope* s = scope; s && !found; s = s.parent) {
        foreach (String mod : s.imports) {
            if (mod == short_module_name || mod.ends_with(string::tformat(".%s", short_module_name))) {
                resolved_module = mod;
                found = true;
                break;
            }
        }
    }

    if (!found) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find module '%s', did you forget to import it?", short_module_name);
    }

    DString resolved_full_name;
    resolved_full_name.tinit();
    resolved_full_name.append(resolved_module);
    resolved_full_name.append(".");
    resolved_full_name.append(function_name);

    next = node;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            next = next.access_node.next;
        case NodeType.CALL:
            FunctionInfo* function_info = get_function_info(context, resolved_full_name.str_view());
            Node*         type_node;

            switch (function_info.node.type) {
            case NodeType.EXT:
                type_node = function_info.node.ext_node.type;
            case NodeType.FUNCTION:
                type_node = function_info.node.function_node.type;
            default:
                highlighter::panic();
            }

            String type_name = get_type_name(context, type_node, scope);

            return type_name.contains(".") ? type_name : string::format(context.alloc, "%s.%s", resolved_module, type_name);
        default:
            highlighter::panic();
        }
    }

    highlighter::panic();
}

fn String traverse_access_variable_base_group(CompileContext* context, Node* node, Scope* scope) => @pool() {
    String        name          = node.access_node.name.path_node.path;
    VariableInfo* variable_info = scope::get_variable(scope, name);
    String        base_group    = lookup::get_base_type_group(context, variable_info.node, scope);

    String type_name = lookup::get_type_name(context, variable_info.node, scope);

    if (base_group == "pointer") {
        type_name = type_name[:type_name.len - 1];
    }

    TypeInfo* type_info = get_type_info(context, type_name);

    return traverse_access_field_base_group(context, node, scope, type_info);
}

fn String traverse_access_field_base_group(CompileContext* context, Node* node, Scope* scope, TypeInfo* type_info) => @pool() {
    String name = node.access_node.name.path_node.path;

    switch (node.access_node.next.type) {
    case NodeType.IDENT:
        break;
    default:
        highlighter::panic("traverse_access_field#access");
    }

    String   field_name = node.access_node.next.ident_node.name;
    NodeList fields     = lookup::get_type_fields(context, type_info, scope);
    String   field_type = lookup::get_type_name(context, node.access_node.name, scope);

    Node* field_node;
    foreach (Node* field : fields) {
        if (field.parameter_node.name.ident_node.name == field_name) {
            field_node = field;
            break;
        }
    }

    return get_base_type_group(context, field_node, scope);
}

fn String traverse_access_module_base_group(CompileContext* context, Node* node, Scope* scope) => @pool() {
    DString full_name;
    full_name.tinit();

    String function_name;

    Node* next = node;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            full_name.append(next.access_node.name.ident_node.name);
            full_name.append(".");

            next = next.access_node.next;
        case NodeType.CALL:
            full_name.append(next.call_node.name.ident_node.name);
            function_name = next.call_node.name.ident_node.name;

            next = null;
        default:
            highlighter::panic();
        }
    }

    String short_module_name = full_name.str_view().strip_suffix(string::tformat(".%s", function_name));

    String resolved_module;
    bool   found = false;

    for (Scope* s = scope; s && !found; s = s.parent) {
        foreach (String mod : s.imports) {
            if (mod == short_module_name || mod.ends_with(string::tformat(".%s", short_module_name))) {
                resolved_module = mod;
                found = true;
                break;
            }
        }
    }

    if (!found) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find module '%s', did you forget to import it?", short_module_name);
    }

    DString resolved_full_name;
    resolved_full_name.tinit();
    resolved_full_name.append(resolved_module);
    resolved_full_name.append(".");
    resolved_full_name.append(function_name);

    next = node;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            next = next.access_node.next;
        case NodeType.CALL:
            FunctionInfo* function_info = get_function_info(context, resolved_full_name.str_view());
            Node*         type_node;

            switch (function_info.node.type) {
            case NodeType.EXT:
                type_node = function_info.node.ext_node.type;
            case NodeType.FUNCTION:
                type_node = function_info.node.function_node.type;
            default:
                highlighter::panic();
            }

            return get_base_type_group(context, type_node, scope);
        default:
            highlighter::panic();
        }
    }

    highlighter::panic();
}

fn TypeInfo* get_type_info(CompileContext* context, String name) {
    if (context.lookup.has_key(name)) {
        Type*     type      = context.lookup.get(name)!!;
        TypeInfo* type_info = alloc::new(context.alloc, TypeInfo);

        type_info.name      = name;
        type_info.node      = type.node;
        type_info.llvm_type = type.llvm_type;

        return type_info;
    }

    String qualified_name = name.contains(".")
        ? name
        : string::tformat("%s.%s", context.current_module, name);

    TypeInfo* type_info;
    foreach (String type_name : context.registry.types.tkeys()) {
        if (type_name == name ||
            type_name.ends_with(string::tformat(".%s", name))) {
            type_info = context.registry.types.get(type_name)!!;
            break;
        }
    }

    return type_info;
}

fn FunctionInfo* get_function_info(CompileContext* context, String name) {
    String qualified_name = name.contains(".")
        ? name
        : string::tformat("%s.%s", context.current_module, name);

    return context.registry.functions.get(qualified_name) ?? null;
}
