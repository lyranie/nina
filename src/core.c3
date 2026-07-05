module nina::core;

import nina::args;
import nina::types;
import nina::lookup;
import nina::profiler;

import std::io;
import std::os;

DynamicArenaAllocator arena @private;

fn Allocator alloc_create() {
    arena.init(mem, 64 * 1024);

    return &arena;
}

fn void alloc_free() {
    arena.reset();
    arena.free();
}

fn CompileContext* context_create() {
    Allocator       alloc   = alloc_create();
    CompileContext* context = alloc::new(alloc, CompileContext);

    context.alloc    = alloc;
    context.profiler = profiler::create(alloc);
    context.args     = args::create(alloc);
    context.lookup   = lookup::create(alloc);
    context.mods.init(alloc);

    return context;
}

fn void context_free(CompileContext* context) {
    alloc_free();
}

fn bool range_compare(Range range, Range other) {
    return range.line   != other.line ||
           range.column != other.column;
}

fn void node_free(Node* node, Allocator alloc) {
    switch (node.type) {
    case NodeType.MOD:
        node_free(node.mod_node.path, alloc);

        foreach (Node* statement : node.mod_node.statements) {
            node_free(statement, alloc);
        }
    case NodeType.PATH:
        alloc::free(alloc, node.path_node.path);
    case NodeType.TYPE:
        node_free(node.type_node.name, alloc);

        alloc::free(alloc, node.type_node.suffix);
    case NodeType.IDENT:
        alloc::free(alloc, node.ident_node.name);
    case NodeType.PARAMETER:
        if (node.parameter_node.type) {
            node_free(node.parameter_node.type, alloc);
        }

        node_free(node.parameter_node.name, alloc);
    case NodeType.RET:
        node_free(node.ret_node.value, alloc);
    case NodeType.FUNCTION:
        node_free(node.function_node.type, alloc);
        node_free(node.function_node.name, alloc);

        foreach (Node* parameter : node.function_node.parameters) {
            node_free(parameter, alloc);
        }

        foreach (Node* statement : node.function_node.statements) {
            node_free(statement, alloc);
        }
    case NodeType.BIN:
        node_free(node.bin_node.left, alloc);
        node_free(node.bin_node.right, alloc);
    case NodeType.INT:
        break;
    case NodeType.EXT:
        node_free(node.ext_node.type, alloc);
        node_free(node.ext_node.name, alloc);

        foreach (Node* parameter : node.ext_node.parameters) {
            node_free(parameter, alloc);
        }
    case NodeType.CALL:
        node_free(node.call_node.name, alloc);

        foreach (Node* argument : node.call_node.arguments) {
            node_free(argument, alloc);
        }
    case NodeType.BOOL:
        break;
    case NodeType.STRING:
        alloc::free(alloc, node.string_node.string);
    default:
        io::eprintfn("Missing node_free call for type %s", node.type);
        os::exit(1);
    }
}
