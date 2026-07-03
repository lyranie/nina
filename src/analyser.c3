module nina::analyser;

import nina::scope;
import nina::types;

import std::collections::map;
import std::io;
import std::os;

fn Analyser* create(Allocator alloc) {
    Analyser* analyser = alloc::new(alloc, Analyser);

    analyser.scope = scope::create(alloc);

    return analyser;
}

fn void analyse(Analyser* analyser, CompileContext* context, Parser* parser) {
    analyse_node(analyser, context, parser.context.ast);
}

fn void analyse_node(Analyser* analyser, CompileContext* context, Node* node, void* data = null) {
    switch (node.type) {
    case NodeType.MOD:
        analyse_mod(analyser, context, node);
    case NodeType.FUNCTION:
        analyse_function(analyser, context, node);
    case NodeType.TYPE:
        analyse_type(analyser, context, node);
    case NodeType.RET:
        analyse_ret(analyser, context, node, data);
    case NodeType.INT:
        break;
    default:
        io::eprintfn("missing analyser function for type '%s'", node.type);
        os::exit(1);
    }
}

fn void analyse_mod(Analyser* analyser, CompileContext* context, Node* node) {
    String path = node.mod_node.path.path_node.path;

    if (context.mods.has_key(context.current_file)) {
        io::eprintfn("Module '%s' already declared in '%s'", context.mods.get(context.current_file), context.current_file)!!;
        os::exit(1);
    }

    context.mods.set(context.current_file, path);

    foreach (Node* statement : node.mod_node.statements) {
        analyse_node(analyser, context, statement);
    }
}

fn void analyse_function(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.function_node.type);

    // TODO: check if there is a return statement present for each possible outcome
    Node*  type  = node.function_node.type;
    Scope* scope = scope::create(context.alloc, analyser.scope);

    HashMap{String, Node*} parameters;
    parameters.tinit();

    foreach (Node* parameter : node.function_node.parameters) {
        analyse_node(analyser, context, parameter.parameter_node.type);

        String name = parameter.parameter_node.name.ident_node.name;

        if (parameters.has_key(name)) {
            Node* prev = parameters.get(name)!!;

            io::eprintfn("Parameter '%s' already defined", name);
            io::eprintn("Previous definition was here");
            os::exit(1);
        }

        parameters.set(name, parameter);
        scope::add_variable(analyser.scope, context.alloc, name, parameter);
    }

    foreach (Node* statement : node.function_node.statements) {
        analyse_node(analyser, context, statement, type);
    }

    analyser.scope = analyser.scope.parent;

    parameters.free();
}

fn void analyse_type(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.type_node.name.ident_node.name;

    if (!context.lookup.has_key(name)) {
        io::eprintfn("Could not find type '%s'", name);
        os::exit(1);
    }
}

fn void analyse_ret(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    Node* function_type = (Node*)data;

    // TODO: compare return type to function type

    if (node.ret_node.value) {
        analyse_node(analyser, context, node.ret_node.value);
    }
}

fn void free(Analyser* analyser, Allocator alloc) {
    scope::free(analyser.scope);
}
