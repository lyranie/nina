module nina::lookup;

import llvm;

import nina::types;
import nina::scope;
import nina::highlighter;

import std::io;
import std::os;

fn Lookup* create(Allocator alloc) {
    Lookup* lookup = alloc::new(alloc, Lookup);

    lookup.init(alloc);

    register_type(lookup, alloc, "int",    "<builtin>", null, llvm::int_32_type());
    register_type(lookup, alloc, "bool",   "<builtin>", null, llvm::int_1_type());
    register_type(lookup, alloc, "char",   "<builtin>", null, llvm::int_8_type());
    register_type(lookup, alloc, "long",   "<builtin>", null, llvm::int_64_type());
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

fn LLVMTypeRef get_llvm_type(Lookup* lookup, Node* node) {
    switch (node.type) {
    case NodeType.TYPE:
        String type_name   = node.type_node.name.ident_node.name;
        String type_suffix = node.type_node.suffix;

        LLVMTypeRef llvm_type = lookup.get(type_name).llvm_type!!;

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

        return llvm_type;
    case NodeType.PARAMETER:
        return get_llvm_type(lookup, node.parameter_node.type);
    case NodeType.VARIABLE:
        return get_llvm_type(lookup, node.variable_node.type);
    default:
        io::eprintfn("Missing get_llvm_type case for type '%s'", node.type);
        os::exit(1);
    }
}

fn LLVMMetadataRef get_llvm_debug_type(Allocator alloc, Generator* generator, Lookup* lookup, Node* node) {
    switch (node.type) {
    case NodeType.TYPE:
        String type_name   = node.type_node.name.ident_node.name;
        String type_suffix = node.type_node.suffix;

        LLVMTypeRef     llvm_type       = lookup.get(type_name).llvm_type!!;
        LLVMMetadataRef llvm_debug_type = get_llvm_debug_type_from_kind(alloc, generator, llvm_type);

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
        return get_llvm_debug_type(alloc, generator, lookup, node.parameter_node.type);
    default:
        io::eprintfn("Missing get_llvm_debug_type case for type '%s'", node.type);
        os::exit(1);
    }
}

fn LLVMMetadataRef get_llvm_debug_type_from_kind(Allocator alloc, Generator* generator, LLVMTypeRef llvm_type) {
    switch (llvm::get_type_kind(llvm_type)) {
    case LLVMTypeKind.VOID_TYPE_KIND:
        return null;
    case LLVMTypeKind.INTEGER_TYPE_KIND:
        CUInt  width = llvm::get_int_type_width(llvm_type);
        String name  = string::format(alloc, "i%d", width);

        if (width == 1) {
            name.free(alloc);
            name = "bool";
        }

        return llvm::di_builder_create_basic_type(generator.llvm_debug_builder, (CChar*)name.ptr, (CUInt)name.len, width, 5, LLVMDIFlags.DI_FLAG_ZERO);
    default:
        io::eprintfn("Missing get_llvm_debug_type_from_kind case for type kind '%s'", llvm::get_type_kind(llvm_type));
        os::exit(1);
    }
}

fn bool compare_type(CompileContext* context, Node* node, Node* other, Scope* scope) {
    String node_type  = get_type_name(context, node, scope);
    String other_type = get_type_name(context, other, scope);

    String node_base_group  = get_base_type_group(context, node, scope);
    String other_base_group = get_base_type_group(context, other, scope);

    if (node_base_group == other_base_group) {
        return true;
    }

    if (node_type == other_type) {
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
        String type_name   = node.type_node.name.ident_node.name;
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
        String        name          = node.call_node.name.ident_node.name;
        FunctionInfo* function_info = scope::get_function(scope, name);

        return get_type_name(context, function_info.node, scope);
    case NodeType.ACCESS:
        Node*  path = node.access_node.name;
        String name = path.path_node.path;

        if (scope::has_variable(scope, name)) {
            @todo("get_type_name_access for variable");
            highlighter::panic();
        } else {
            return traverse_access_module(context, node, scope);
        }
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
        LLVMTypeRef  llvm_type      = get_llvm_type(context.lookup, node);
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
        default:
            highlighter::panic("Missing get_base_type_goup#TYPE case for type kind '%s'", llvm_type_kind);
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
        FunctionInfo* function_info = scope::get_function(scope, name);

        return get_base_type_group(context, function_info.node, scope);
    case NodeType.FUNCTION:
        return get_base_type_group(context, node.function_node.type, scope);
    case NodeType.ACCESS:
        Node*  path = node.access_node.name;
        String name = path.path_node.path;

        if (scope::has_variable(scope, name)) {
            @todo("get_type_name_access for variable");
            highlighter::panic();
        } else {
            return traverse_access_module_base_group(context, node, scope);
        }
    default:
        highlighter::panic("Missing get_base_type_group case for type '%s'", node.type);
    }
}

fn String traverse_access_module(CompileContext* context, Node* node, Scope* scope) => @pool() {
    String name = node.access_node.name.path_node.path;
    
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

    String module_name = full_name.str_view().strip_suffix(string::tformat(".%s", function_name));

    next = node;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            next = next.access_node.next;
        case NodeType.CALL:
            FunctionInfo* function_info = context.functions.get(full_name.str_view())!!;
            Node*         type_node;

            switch (function_info.node.type) {
            case NodeType.EXT:
                type_node = function_info.node.ext_node.type;
            case NodeType.FUNCTION:
                type_node = function_info.node.function_node.type;
            default:
                highlighter::panic();
            }

            return get_type_name(context, type_node, scope);
        default:
            highlighter::panic();
        }
    }
    
    highlighter::panic();
}

fn String traverse_access_module_base_group(CompileContext* context, Node* node, Scope* scope) => @pool() {
    String name = node.access_node.name.path_node.path;
    
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

    String module_name = full_name.str_view().strip_suffix(string::tformat(".%s", function_name));

    next = node;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            next = next.access_node.next;
        case NodeType.CALL:
            FunctionInfo* function_info = context.functions.get(full_name.str_view())!!;
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
