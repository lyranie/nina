module nina::lookup;

import llvm;

import nina::types;

import std::io;
import std::os;

fn Lookup* create(Allocator alloc) {
    Lookup* lookup = alloc::new(alloc, Lookup);

    lookup.init(alloc);

    register_type(lookup, alloc, "int",    "<builtin>", null, llvm::int_32_type());
    register_type(lookup, alloc, "char",   "<builtin>", null, llvm::int_8_type());
    register_type(lookup, alloc, "String", "<builtin>", null, llvm::array_type(llvm::int_8_type(), 0));

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

        return llvm::di_builder_create_basic_type(generator.llvm_debug_builder, (CChar*)name.ptr, (CUInt)name.len, width, 5, LLVMDIFlags.DI_FLAG_ZERO);
    default:
        io::eprintfn("Missing get_llvm_debug_type_from_kind case for type kind '%s'", llvm::get_type_kind(llvm_type));
        os::exit(1);
    }
}
