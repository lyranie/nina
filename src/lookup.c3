module nina::lookup;

import llvm;

import nina::types;
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

fn bool compare_type(Lookup* lookup, Allocator alloc, Node* node, Node* other) {
    String node_type  = get_type_name(lookup, alloc, node);
    String other_type = get_type_name(lookup, alloc, other);

    String node_base_group  = get_base_type_group(lookup, alloc, node);
    String other_base_group = get_base_type_group(lookup, alloc, other);

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

fn String get_type_name(Lookup* lookup, Allocator alloc, Node* node) {
    switch (node.type) {
    case NodeType.PARAMETER:
        if (node.parameter_node.type) {
            return get_type_name(lookup, alloc, node.parameter_node.type);
        }

        return "any";
    case NodeType.TYPE:
        String type_name   = node.type_node.name.ident_node.name;
        String type_suffix = node.type_node.suffix;

        return string::format(alloc, "%s%s", type_name, type_suffix);
    case NodeType.INT:
        return "int";
    case NodeType.BOOL:
        return "bool";
    case NodeType.STRING:
        return "string";
    default:
        highlighter::panic("Missing get_type_name case for type '%s'", node.type);
    }
}

fn String get_base_type_group(Lookup* lookup, Allocator alloc, Node* node) {
    switch (node.type) {
    case NodeType.PARAMETER:
        if (node.parameter_node.type) {
            return get_base_type_group(lookup, alloc, node.parameter_node.type);
        }

        return "anytype";
    case NodeType.TYPE:
        String       type_name      = node.type_node.name.ident_node.name;
        LLVMTypeRef  llvm_type      = get_llvm_type(lookup, node);
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
    default:
        highlighter::panic("Missing get_base_type_group case for type '%s'", node.type);
    }
}
