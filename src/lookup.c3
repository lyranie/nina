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
        return get(context, node.function_node.type, scope);
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
            }

            type_group = "integer";
        }

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.CALL:
        FunctionInfo* function_info = get_function_info(context, node.call_node.name.path_node.path);

        return get(context, function_info.node, scope);
    case NodeType.EXT:
        return get(context, node.ext_node.type, scope);
    case NodeType.IDENT:
        String name     = node.ident_node.name;
        Node*  variable = scope::get_variable(scope, name).node;

        return get(context, variable, scope);
    case NodeType.VARIABLE:
        return get(context, node.variable_node.type, scope);
    case NodeType.PARAMETER:
        return get(context, node.parameter_node.type, scope);
    case NodeType.BIN:
        switch (node.bin_node.operator.type) {
        case TokenType.IS_EQUAL:
        case TokenType.NOT_EQUAL:
        case TokenType.GTE:
        case TokenType.LTE:
        case TokenType.LANGLE:
        case TokenType.RANGLE:
            // bool
            TypeInfo*       type_info       = get_type_info(context, "bool");
            LLVMTypeRef     llvm_type       = type_info.llvm_type;
            LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
            String          type_name       = "bool";
            String          type_group      = "boolean";

            return { llvm_type, llvm_debug_type, type_name, type_group };
        default:
            return get(context, node.bin_node.left, scope);
        }
    case NodeType.INT:
        TypeInfo*       type_info       = get_type_info(context, "int");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "int";
        String          type_group      = "integer";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.ACCESS:
        // check if module instead of variable
        String        name          = node.access_node.name.path_node.path;
        VariableInfo* variable_info = scope::get_variable(scope, name);

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

                    return get(context, function_info.node, scope);
                default:
                    full_name.append(next.access_node.name.ident_node.name);

                    next = next.access_node.next;
                }
            }
        }

        LookupElement type_data = get(context, variable_info.node, scope);
        String        type_name = type_data.type_name;

        if (type_data.type_group == "pointer") {
            type_name = type_name[:type_name.len - 1];
        }

        TypeInfo* type_info  = get_type_info(context, type_name);
        NodeList  fields     = get_type_fields(context, type_info, scope);
        String    field_name = node.access_node.next.ident_node.name;

        Node* field_node;
        foreach (Node* field : fields) {
            if (field.parameter_node.name.ident_node.name == field_name) {
                field_node = field;
                break;
            }
        }

        // maybe return null if field_node is null

        return get(context, field_node.parameter_node.type, scope);
    case NodeType.STRING:
        TypeInfo*       type_info       = get_type_info(context, "String");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "string";
        String          type_group      = "pointer";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.RET:
        if (node.ret_node.value) {
            return get(context, node.ret_node.value, scope);
        }

        TypeInfo*       type_info       = get_type_info(context, "void");
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = "void";
        String          type_group      = "void";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.NULL:
        // change `null` to pointertype later
        LLVMTypeRef     llvm_type       = null;
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

        return get(context, type_info.node, scope);
    case NodeType.STRUCT:
        String          name            = node.type_node.name.ident_node.name;
        TypeInfo*       type_info       = get_type_info(context, name);
        LLVMTypeRef     llvm_type       = type_info.llvm_type;
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, type_info);
        String          type_name       = name;
        String          type_group      = "struct";

        return { llvm_type, llvm_debug_type, type_name, type_group };
    case NodeType.DEREFERENCE:
        LookupElement type_data = get(context, node.dereference_node.node, scope);

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
        LookupElement type_data = get(context, node.reference_node.node, scope);

        LLVMTypeRef     llvm_type       = llvm::pointer_type(type_data.llvm_type, 0);
        LLVMMetadataRef llvm_debug_type = create_debug_type(context, generator, llvm_type, null, type_data.llvm_debug_type);
        String          type_name       = string::format(context.alloc, "%s*", type_data.type_name);
        String          type_group      = "pointer";

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

        io::printn(name);
        io::printn(width);
        io::printn(generator.llvm_debug_builder);

        return llvm::di_builder_create_basic_type(generator.llvm_debug_builder, (CChar*)name.ptr, (CUInt)name.len, width, 5, LLVMDIFlags.DI_FLAG_ZERO);
    case LLVMTypeKind.STRUCT_TYPE_KIND:
        String name = ((ZString)llvm::get_struct_name(llvm_type)).str_view().copy(context.alloc);

        uint size_in_bits  = 0;
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
            type_info ? (CUInt)type_info.node.range.from.line : 0,
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
