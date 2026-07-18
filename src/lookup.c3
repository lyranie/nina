module nina::lookup;

import llvm;

import nina::types;
import nina::scope;
import nina::highlighter;

import std::io;
import std::os;
import std::collections::list;

fn Lookup* create(Allocator alloc, LLVMContextRef llvm_context) {
    Lookup* lookup = alloc::new(alloc, Lookup);

    lookup.init(alloc);

    register_type(lookup, alloc, "int",    "<builtin>", null, llvm::int_32_type());
    register_type(lookup, alloc, "bool",   "<builtin>", null, llvm::int_1_type());
    register_type(lookup, alloc, "char",   "<builtin>", null, llvm::int_8_type());
    register_type(lookup, alloc, "long",   "<builtin>", null, llvm::int_64_type());
    register_type(lookup, alloc, "real",   "<builtin>", null, llvm::double_type());
    register_type(lookup, alloc, "void",   "<builtin>", null, llvm::void_type());
    register_type(lookup, alloc, "String", "<builtin>", null, llvm::slice_type(llvm::int_8_type()));

    LLVMTypeRef any_type = llvm::struct_create_named(llvm_context, "any");
    llvm::struct_set_body(any_type, (LLVMTypeRef[]){ llvm::pointer_type(llvm::int_8_type(), 0), llvm::int_32_type() }, 2, llvm::FALSE);

    register_type(lookup, alloc, "any", "<builtin>", null, any_type);

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

fn bool compare_type(CompileContext* context, Node* node, Node* other, Scope* scope) {
    LookupElement node_data  = get(context, node, scope);
    LookupElement other_data = get(context, other, scope);

    TypeInfo* node_type_info  = get_type_info(context, node_data.type_name);
    TypeInfo* other_type_info = get_type_info(context, other_data.type_name);

    if (node_data.type_group == other_data.type_group) {
        return true;
    }

    if (node_data.type_name == other_data.type_name) {
        return true;
    }

    if (node_type_info && node_type_info == other_type_info) {
        return true;
    }

    if (node_data.type_group == "integer" && other_data.type_group == "integer") {
        return true;
    }

    if (node_data.type_name == "any") {
        return true;
    }

    return false;
}

fn NodeList get_type_fields(CompileContext* context, TypeInfo* type_info, Scope* scope) {
    switch (type_info.node.type) {
    case NodeType.STRUCT:
        return type_info.node.struct_node.fields;
    default:
        highlighter::panic();
    }
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

// potentially remove type_group alltogether
fn LookupElement get(CompileContext* context, Node* node, Scope* scope, Generator* generator = null) {
    switch (node.type) {
    case NodeType.FUNCTION:
        return get(context, node.function_node.type, scope, generator);
    case NodeType.TYPE:
        String name        = node.type_node.name.ident_node.name;
        String type_suffix = node.type_node.suffix;

        TypeInfo*       type_info       = get_type_info(context, name);
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);

        while (type_suffix.ends_with("*") || type_suffix.ends_with("[]")) {
            switch (type_suffix[type_suffix.len - 1]) {
            case '*':
                type_suffix = type_suffix[:type_suffix.len - 1];
                llvm_type   = llvm::pointer_type(llvm_type, 0);
                llvm_debug_type = create_debug_type(context, generator, llvm_type, null, llvm_debug_type);
            case ']':
                type_suffix = type_suffix[:type_suffix.len - 1];
                llvm_type   = llvm::slice_type(llvm_type);
                llvm_debug_type = create_debug_type(context, generator, llvm_type, null, llvm_debug_type);
            }
        }

        LLVMTypeKind llvm_type_kind = llvm::get_type_kind(llvm_type);

        if (llvm::get_type_kind(llvm_type) == LLVMTypeKind.STRUCT_TYPE_KIND && llvm::is_opaque_struct(llvm_type)) {
            List{LLVMTypeRef} llvm_fields;
            llvm_fields.tinit();

            foreach (Node* field : type_info.node.struct_node.fields) {
                llvm_fields.push(get(context, field.parameter_node.type, scope).llvm_type);
            }

            llvm::struct_set_body(llvm_type, llvm_fields.to_array(context.alloc), (CUInt)llvm_fields.len(), llvm::FALSE);
        }

        String type_name  = string::format(context.alloc, "%s%s", name, node.type_node.suffix);
        String type_group = node.type_node.suffix.ends_with("*") ? "pointer" : "";

        switch (llvm_type_kind) {
        case LLVMTypeKind.INTEGER_TYPE_KIND:
            CUInt width = llvm::get_int_type_width(llvm_type);

            if (width == 1) {
                type_group = "boolean";
            } else {
                type_group = "integer";
            }
        case LLVMTypeKind.POINTER_TYPE_KIND:
            type_group = "pointer";
        case LLVMTypeKind.STRUCT_TYPE_KIND:
            type_group = "struct";
        }

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.CALL:
        FunctionInfo* function_info = get_function_info(context, node.call_node.name.path_node.path);

        return get(context, function_info.node, scope, generator);
    case NodeType.EXT:
        return get(context, node.ext_node.type, scope, generator);
    case NodeType.IDENT:
        String name     = node.ident_node.name;
        Node*  variable = scope::get_variable(scope, name).node;

        return get(context, variable, scope, generator);
    case NodeType.VARIABLE:
        return get(context, node.variable_node.type, scope, generator);
    case NodeType.PARAMETER:
        return get(context, node.parameter_node.type, scope, generator);
    case NodeType.BIN:
        switch (node.bin_node.operator.type) {
        case TokenType.IS_EQUAL:
        case TokenType.NOT_EQUAL:
        case TokenType.GTE:
        case TokenType.LTE:
        case TokenType.LANGLE:
        case TokenType.RANGLE:
            TypeInfo*       type_info       = get_type_info(context, "bool");
            LLVMTypeRef     llvm_type       = type_info.llvm_type;
            LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
            String          type_name       = "bool";
            String          type_group      = "boolean";

            return { llvm_type, llvm_debug_type, type_name, type_group };
        default:
            return get(context, node.bin_node.left, scope, generator);
        }
    case NodeType.INT:
        TypeInfo*       type_info       = get_type_info(context, "int");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "int";
        String          type_group      = "integer";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.ACCESS:
        String name = node.access_node.name.path_node.path;

        if (scope::has_import(scope, name)) {
            DString full_name;
            full_name.init(context.alloc);

            Node* next = node;
            while (next) {
                switch (next.type) {
                case NodeType.CALL:
                    String function_name     = next.call_node.name.path_node.path;
                    String short_module_name = full_name.str_view().strip_suffix(string::tformat(".%s", function_name));
                    String resolved_module;

                    if (scope::has_import(scope, short_module_name)) {
                        resolved_module = scope::get_import(scope, short_module_name);
                    }

                    String        call_name     = string::format(context.alloc, "%s.%s", resolved_module, function_name);
                    FunctionInfo* function_info = get_function_info(context, call_name);

                    return get(context, function_info.node, scope, generator);
                default:
                    full_name.append(next.access_node.name.ident_node.name);

                    next = next.access_node.next;
                }
            }

            highlighter::panic();
        } else if (scope::has_variable(scope, name)) {
            VariableInfo* variable_info = scope::get_variable(scope, name);

            LookupElement base;
            if (scope::has_narrowed_type(scope, name)) {
                base = scope::get_narrowed_type(scope, name);
            } else {
                base = get(context, variable_info.node, scope, generator);
            }

            Node* next = node.access_node.next;

            while (next) {
                String field_name;
                Node*  after;

                switch (next.type) {
                case NodeType.IDENT:
                    field_name = next.ident_node.name;
                    after      = null;
                case NodeType.ACCESS:
                    field_name = next.access_node.name.ident_node.name;
                    after      = next.access_node.next;
                default:
                    highlighter::panic();
                }

                FieldResult result = get_field(context, scope, base, field_name);

                if (result.field_node) {
                    base = get(context, result.field_node.parameter_node.type, scope, generator);
                } else if (result.lookup_element.type_name != "") {
                    base = result.lookup_element;
                } else {
                    highlighter::panic("Could not find field '%s' on type '%s'", field_name, base.type_name);
                }

                next = after;
            }

            return base;
        } else {
            TypeInfo* type_info = get_type_info(context, name);

            LookupElement base = { .llvm_type = type_info.llvm_type, .type_name = type_info.name };

            Node* next = node.access_node.next;

            while (next) {
                String field_name;
                Node*  after;

                switch (next.type) {
                case NodeType.IDENT:
                    field_name = next.ident_node.name;
                    after      = null;
                case NodeType.ACCESS:
                    field_name = next.access_node.name.ident_node.name;
                    after      = next.access_node.next;
                default:
                    highlighter::panic();
                }

                FieldResult result = get_field(context, scope, base, field_name);

                if (result.field_node) {
                    base = get(context, result.field_node.parameter_node.type, scope, generator);
                } else if (result.lookup_element.type_name != "") {
                    base = result.lookup_element;
                } else {
                    highlighter::panic("Could not find field '%s' on type '%s'", field_name, base.type_name);
                }

                next = after;
            }

            return base;
        }
    case NodeType.STRING:
        TypeInfo*       type_info       = get_type_info(context, "String");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "string";
        String          type_group      = "pointer";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.RET:
        if (node.ret_node.value) {
            return get(context, node.ret_node.value, scope, generator);
        }

        TypeInfo*       type_info       = get_type_info(context, "void");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "void";
        String          type_group      = "void";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.NULL:
        LLVMTypeRef     llvm_type       = llvm::pointer_type(llvm::int_8_type(), 0);
        LLVMMetadataRef llvm_debug_type = generator ? llvm::di_builder_create_basic_type(generator.llvm_debug_builder, "null", 4, 64, 5, LLVMDIFlags.DI_FLAG_ZERO) : null;
        String          type_name       = "null";
        String          type_group      = "pointer";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.BOOL:
        TypeInfo*       type_info       = get_type_info(context, "bool");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "bool";
        String          type_group      = "boolean";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.INIT:
        TypeInfo* type_info = get_type_info(context, node.init_node.name.path_node.path);

        return get(context, type_info.node, scope, generator);
    case NodeType.STRUCT:
        String          name            = node.type_node.name.ident_node.name;
        TypeInfo*       type_info       = get_type_info(context, name);
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = name;
        String          type_group      = "struct";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.DEREFERENCE:
        LookupElement type_data = get(context, node.dereference_node.node, scope, generator);

        LLVMTypeKind pointee_type_kind = llvm::get_type_kind(type_data.llvm_type);

        switch (pointee_type_kind) {
        case LLVMTypeKind.INTEGER_TYPE_KIND:
            CUInt width = llvm::get_int_type_width(type_data.llvm_type);

            if (width == 1) {
                TypeInfo*       type_info       = get_type_info(context, "bool");
                LLVMTypeRef     llvm_type       = type_info.llvm_type;
                LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
                String          type_name       = "bool";
                String          type_group      = "boolean";

                return { llvm_type, llvm_debug_type, type_name, type_group };
            }

            TypeInfo*       type_info       = get_type_info(context, "int");
            LLVMTypeRef     llvm_type       = type_info.llvm_type;
            LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
            String          type_name       = "int";
            String          type_group      = "integer";

            return { llvm_type, llvm_debug_type, type_name, type_group };
        case LLVMTypeKind.POINTER_TYPE_KIND:
            String    new_type_name = type_data.type_name[:type_data.type_name.len - 1];
            TypeInfo* type_info     = get_type_info(context, new_type_name);

            LLVMTypeRef     llvm_type       = type_info.llvm_type;
            LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
            String          type_name       = new_type_name;
            String          type_group;

            switch (llvm::get_type_kind(llvm_type)) {
            case LLVMTypeKind.INTEGER_TYPE_KIND:
                type_group = llvm::get_int_type_width(llvm_type) == 1 ? "boolean" : "integer";
            case LLVMTypeKind.POINTER_TYPE_KIND:
                type_group = "pointer";
            case LLVMTypeKind.STRUCT_TYPE_KIND:
                type_group = "struct";
            default:
                highlighter::panic();
            }

            return { llvm_type, llvm_debug_type, type_name, type_group };
        case LLVMTypeKind.STRUCT_TYPE_KIND:
            io::printn("struct");
            highlighter::panic();
        default:
            highlighter::panic("Missing get_base_type_group#DEREFERENCE case for type kind '%s'", pointee_type_kind);
        }
    case NodeType.REFERENCE:
        LookupElement type_data = get(context, node.reference_node.node, scope, generator);

        LLVMTypeRef     llvm_type       = llvm::pointer_type(type_data.llvm_type, 0);
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, null, type_data.llvm_debug_type);
        String          type_name       = string::format(context.alloc, "%s*", type_data.type_name);
        String          type_group      = "pointer";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.UNARY:
        switch (node.unary_node.operator.type) {
        case TokenType.BANG:
            TypeInfo*       type_info       = get_type_info(context, "bool");
            LLVMTypeRef     llvm_type       = type_info.llvm_type;
            LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
            String          type_name       = "bool";
            String          type_group      = "boolean";

            return { llvm_type, llvm_debug_type, type_name, type_group };
        default:
            return get(context, node.bin_node.left, scope, generator);
        }
    case NodeType.REAL:
        TypeInfo*       type_info       = get_type_info(context, "real");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "real";
        String          type_group      = "real";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.CHAR:
        TypeInfo*       type_info       = get_type_info(context, "char");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "char";
        String          type_group      = "character";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    default:
        highlighter::panic("Missing lookup::get case for type '%s'", node.type);
    }
}

fn LLVMMetadataRef create_debug_type(CompileContext* context, Generator* generator, LLVMTypeRef llvm_type, TypeInfo* type_info = null, LLVMMetadataRef pointee_debug_type = null) {
    if (!generator || !generator.llvm_debug_builder) {
        return null;
    }

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

        CUInt field_count = llvm::count_struct_element_types(llvm_type);

        List{LLVMMetadataRef} member_types;
        member_types.init(context.alloc);

        uint offset_in_bits = 0;
        uint size_in_bits    = 0;
        uint align_in_bits   = 0;

        for (CUInt i = 0; i < field_count; i++) {
            LLVMTypeRef field_llvm_type = llvm::struct_get_type_at_index(llvm_type, i);
            LLVMMetadataRef field_debug_type = create_debug_type(context, generator, field_llvm_type);

            uint field_size_bits;
            switch (llvm::get_type_kind(field_llvm_type)) {
            case LLVMTypeKind.INTEGER_TYPE_KIND:
                field_size_bits = llvm::get_int_type_width(field_llvm_type);
            case LLVMTypeKind.POINTER_TYPE_KIND:
                field_size_bits = 64;
            default:
                field_size_bits = 64;
            }

            LLVMMetadataRef member = llvm::di_builder_create_member_type(
                generator.llvm_debug_builder,
                null,
                (CChar*)"".ptr, 0,
                generator.llvm_debug_file,
                0,
                field_size_bits,
                field_size_bits,
                offset_in_bits,
                LLVMDIFlags.DI_FLAG_ZERO,
                field_debug_type
            );

            member_types.push(member);

            offset_in_bits += field_size_bits;
            size_in_bits    += field_size_bits;
            if (field_size_bits > align_in_bits) {
                align_in_bits = field_size_bits;
            }
        }

        return llvm::di_builder_create_struct_type(
            generator.llvm_debug_builder,
            generator.llvm_debug_file,
            (CChar*)name.ptr,
            name.len,
            generator.llvm_debug_file,
            type_info && type_info.node ? (CUInt)type_info.node.range.from.line : 0,
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
    case LLVMTypeKind.POINTER_TYPE_KIND:
        return llvm::di_builder_create_pointer_type(generator.llvm_debug_builder, pointee_debug_type, 64, 0, 0, null, 0);
    default:
        highlighter::panic("Missing create_debug_type case for type kind '%s'", llvm::get_type_kind(llvm_type));
    }
}

fn FieldResult get_field(CompileContext* context, Scope* scope, LookupElement base, String field_name) {
    if (field_name.starts_with("$")) {
        switch (field_name) {
        case "$size":
        case "$typeid":
            return { .lookup_element = { .type_name = "int", .type_group = "integer" } };
        case "$data":
            return { .lookup_element = base, .field_node = null };
        default:
            return {};
        }
    }

    String type_name = base.type_name;

    if (base.type_group == "pointer") {
        type_name = type_name[:type_name.len - 1];
    } else if (base.type_group != "struct") {
        highlighter::panic("cannot access field on non-struct type");
    }

    TypeInfo* type_info = lookup::get_type_info(context, type_name);
    NodeList  fields    = get_type_fields(context, type_info, scope);

    foreach (Node* field : fields) {
        if (field.parameter_node.name.ident_node.name == field_name) {
            return { .field_node = field };
        }
    }

    return {};
}

fn int get_type_size(CompileContext* context, Scope* scope, LookupElement element) {
    switch (element.type_group) {
    case "integer":
        return 4;
    case "real":
        return 8;
    case "pointer":
        return 8;
    case "boolean":
        return 1;
    case "struct":
        TypeInfo* type_info = get_type_info(context, element.type_name);
        NodeList  fields    = get_type_fields(context, type_info, scope);

        int size;
        foreach (Node* field : fields) {
            LookupElement field_element = get(context, field, scope);
            size += get_type_size(context, scope, field_element);
        }

        return size;
    case "":
        // hack for now until i figure out how to get the type group from TypeInfo
        TypeInfo* type_info = get_type_info(context, element.type_name);
        NodeList  fields    = get_type_fields(context, type_info, scope);

        int size;
        foreach (Node* field : fields) {
            LookupElement field_element = get(context, field, scope);
            size += get_type_size(context, scope, field_element);
        }

        return size;
    default:
        highlighter::panic("cannot get size of type group '%s'", element.type_group);
    }
}
