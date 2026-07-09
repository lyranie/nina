module nina::analyser;

import nina::scope;
import nina::types;
import nina::lookup;
import nina::highlighter;

import std::collections::map;
import std::io;
import std::os;

fn Analyser* create(CompileContext* context, String path) {
    context.current_file = path;

    Analyser* analyser = alloc::new(context.alloc, Analyser);
    String    mod      = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
    
    analyser.scope       = scope::create(context.alloc);
    analyser.module_name = mod;
    analyser.imports.init(context.alloc);

    return analyser;
}

fn void analyse(Analyser* analyser, CompileContext* context) {
    analyse_node(analyser, context, context.trees.get(context.current_file))!!;
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
    case NodeType.EXT:
        analyse_ext(analyser, context, node);
    case NodeType.CALL:
        analyse_call(analyser, context, node);
    case NodeType.BOOL:
        break;
    case NodeType.STRING:
        break;
    case NodeType.BIN:
        analyse_bin(analyser, context, node);
    case NodeType.IDENT:
        analyse_ident(analyser, context, node);
    case NodeType.VARIABLE:
        analyse_variable(analyser, context, node);
    case NodeType.USE:
        analyse_use(analyser, context, node);
    case NodeType.ACCESS:
        analyse_access(analyser, context, node);
    case NodeType.UNARY:
        analyse_unary(analyser, context, node);
    case NodeType.IF:
        analyse_if(analyser, context, node);
    case NodeType.STRUCT:
        analyse_struct(analyser, context, node);
    case NodeType.INIT:
        analyse_init(analyser, context, node);
    default:
        highlighter::panic("Missing analyser function for type '%s'", node.type);
    }
}

fn void analyse_mod(Analyser* analyser, CompileContext* context, Node* node) {
    String path = node.mod_node.path.path_node.path;

    if (context.mods.has_key(path)) {
        highlighter::error(
            context,
            node.mod_node.path.range.from,
            node.mod_node.path.range.to,
            "Module '%s' already declared in file '%s'", path, context.mods.get(path)
        )!!;
    }

    context.mods.set(path, context.current_file);

    foreach (Node* statement : node.mod_node.statements) {
        analyse_node(analyser, context, statement);
    }
}

fn void analyse_function(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.function_node.type);

    String name = node.function_node.name.ident_node.name;
    if (scope::has_function(analyser.scope, name)) {
        FunctionInfo* prev = scope::get_function(analyser.scope, name);

        highlighter::note(context, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Function '%s' already defined", name);
    }

    scope::add_function(analyser.scope, context.alloc, name, analyser.module_name, context.current_file, node);

    if (!always_returns(analyser, context, node) && lookup::get_type_name(context, node, analyser.scope) != "void")
    {
        highlighter::error(context, node.range.from, node.range.to, "Missing return at end of function");
    }

    Node* type = node.function_node.type;
    analyser.scope = scope::create(context.alloc, analyser.scope);

    HashMap{String, Node*} parameters;
    parameters.tinit();

    foreach (Node* parameter : node.function_node.parameters) {
        analyse_node(analyser, context, parameter.parameter_node.type);

        String parameter_name = parameter.parameter_node.name.ident_node.name;

        if (parameters.has_key(parameter_name)) {
            Node* prev = parameters.get(parameter_name)!!;

            highlighter::note(context, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, parameter.range.from, parameter.range.to, "Parameter '%s' already defined", parameter_name);
        }

        parameters.set(parameter_name, parameter);
        scope::add_variable(analyser.scope, context.alloc, parameter_name, parameter);
    }

    analyse_compound(analyser, context, node.function_node.statements, type);

    analyser.scope = analyser.scope.parent;

    parameters.free();
}

fn void analyse_type(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.type_node.name.ident_node.name;

    if (!context.lookup.has_key(name)) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find type '%s'", name);
    }
}

fn void analyse_ret(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    Node* function_type = (Node*)data;

    @todo("compare return type to function type");

    if (node.ret_node.value) {
        analyse_node(analyser, context, node.ret_node.value);
    }
}

fn void analyse_ext(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.ext_node.type);

    String name = node.ext_node.name.ident_node.name;
    if (scope::has_function(analyser.scope, name)) {
        FunctionInfo* prev = scope::get_function(analyser.scope, name);
        
        highlighter::note(context, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Function '%s' already defined", name);
    }

    scope::add_function(analyser.scope, context.alloc, name, analyser.module_name, context.current_file, node);

    HashMap{String, Node*} parameters;
    parameters.tinit();

    foreach (Node* parameter : node.ext_node.parameters) {
        if (parameter.parameter_node.type) {
            analyse_node(analyser, context, parameter.parameter_node.type);
        }

        String parameter_name = parameter.parameter_node.name.ident_node.name;

        if (parameters.has_key(parameter_name)) {
            Node* prev = parameters.get(parameter_name)!!;

            highlighter::note(context, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, parameter.range.from, parameter.range.to, "Parameter '%s' already defined", parameter_name);
        }

        parameters.set(parameter_name, parameter);
        scope::add_variable(analyser.scope, context.alloc, parameter_name, parameter);
    }
}

fn void analyse_call(Analyser* analyser, CompileContext* context, Node* node) => @pool() {
    String        name          = node.call_node.name.path_node.path;
    String        full_name     = string::tformat("%s.%s", analyser.module_name, name);
    FunctionInfo* function_info = context.functions.get(full_name) ?? scope::get_function(analyser.scope, name);

    handle_call(analyser, context, node, name, analyser.module_name, function_info);
}

fn void analyse_bin(Analyser* analyser, CompileContext* context, Node* node) {
    @todo("check if operator is applicable to type");

    analyse_node(analyser, context, node.bin_node.left);
    analyse_node(analyser, context, node.bin_node.right);

    if (!lookup::compare_type(context, node.bin_node.left, node.bin_node.right, analyser.scope)) {
        String left_type  = lookup::get_type_name(context, node.bin_node.left, analyser.scope);
        String right_type = lookup::get_type_name(context, node.bin_node.right, analyser.scope);

        highlighter::error(context, node.range.from, node.range.to, "Cannot operate type '%s' with type '%s'", left_type, right_type);
    }
}

fn void analyse_ident(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.ident_node.name;

    if (!scope::has_variable(analyser.scope, name)) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find variable '%s'", name);
    }
}

fn void analyse_variable(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.variable_node.type);

    String name = node.variable_node.name.ident_node.name;

    if (scope::has_variable(analyser.scope, name)) {
        VariableInfo* prev = scope::get_variable(analyser.scope, name);
        
        highlighter::note(context, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Variable '%s' already defined", name);
    }

    scope::add_variable(analyser.scope, context.alloc, name, node);

    if (node.variable_node.value) {
        analyse_node(analyser, context, node.variable_node.value);

        @todo("check if value type matches variable type");
    }
}

<*
  @param type : `The Function return type`
*>
fn void analyse_compound(Analyser* analyser, CompileContext* context, NodeList statements, Node* type) {
    bool returned;

    foreach (int index, Node* statement : statements)
    {
        analyse_node(analyser, context, statement, type);

        if (returned)
        {
            highlighter::warn(context, statement.range.from, statement.range.to, "Statement will never be executed");
        }

        if (statement.type == NodeType.RET && index != statements.len() - 1)
        {
            returned = true;
            highlighter::note(context, statement.range.from, statement.range.to, "No statement will be executed after return");
        }
    }
}

fn void analyse_use(Analyser* analyser, CompileContext* context, Node* node) {
    String path = node.use_node.path.path_node.path;

    bool found = false;
    foreach (Node* tree : context.trees.values(context.alloc)) {
        if (tree.mod_node.path.path_node.path == path) {
            found = true;
            break;
        }
    }

    if (!found) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find module '%s'", path);
    }

    analyser.imports.push(path);
}

fn void analyse_access(Analyser* analyser, CompileContext* context, Node* node) {
    Node*  path = node.access_node.name;
    String name = path.path_node.path;

    if (scope::has_variable(analyser.scope, name)) {
        traverse_access_variable(analyser, context, node);
    } else {
        bool module_found = false;

        foreach (String mod : analyser.imports) {
            if (mod == name || mod.starts_with(string::tformat("%s.", name))) {
                module_found = true;
                break;
            }
        }

        if (module_found) {
            traverse_access_module(analyser, context, node);
        } else {
            highlighter::error(context, path.range.from, path.range.to, "Could not find '%s'", name);
        }
    }
}

fn void analyse_unary(Analyser* analyser, CompileContext* context, Node* node) {
    @todo("check if operator is applickable to expr");
}

fn void analyse_if(Analyser* analyser, CompileContext* context, Node* node) {
    @todo("check if condition type is passable");

    analyse_node(analyser, context, node.if_node.condition);

    foreach (Node* statement : node.if_node.then_statements) {
        analyse_node(analyser, context, statement);
    }

    foreach (Node* statement : node.if_node.else_statements) {
        analyse_node(analyser, context, statement);
    }

    if (node.if_node.else_if) {
        analyse_node(analyser, context, node.if_node.else_if);
    }
}

fn void analyse_struct(Analyser* analyser, CompileContext* context, Node* node) => @pool() {
    String name = node.struct_node.name.ident_node.name;

    if (scope::has_type(analyser.scope, name)) {
        TypeInfo* prev = scope::get_type(analyser.scope, name);
        
        highlighter::note(context, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Type '%s' already defined", name);
    }

    scope::add_type(analyser.scope, context.alloc, name, analyser.module_name, context.current_file, node);

    HashMap{String, Node*} fields;
    fields.tinit();

    foreach (Node* field : node.struct_node.fields) {
        analyse_node(analyser, context, field.parameter_node.type);

        String field_name = field.parameter_node.name.ident_node.name;

        if (fields.has_key(field_name)) {
            Node* prev = fields.get(field_name)!!;

            highlighter::note(context, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, field.range.from, field.range.to, "Field '%s' already defined", field_name);
        }

        fields.set(field_name, field);
    }
}

fn void analyse_init(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.struct_node.name.ident_node.name;

    if (!scope::has_type(analyser.scope, name)) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find type '%s'", name);
    }

    TypeInfo* type_info = scope::get_type(analyser.scope, name);
    NodeList  fields    = type_info.node.struct_node.fields;

    int arguments_len = (int)node.init_node.arguments.len();
    int fields_len    = (int)fields.len();
    
    if (arguments_len < fields_len) {
        highlighter::note(context, type_info.node.range.from, type_info.node.range.to, "Definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Expected more arguments");
    }

    if (arguments_len > fields_len) {
        Node* argument = node.init_node.arguments[(long)arguments_len - 1];

        highlighter::error(context, argument.range.from, argument.range.to, "Expected less arguments");
    }

    foreach (int i, Node* argument : node.init_node.arguments) {
        if (i >= fields_len) {
            break;
        }

        Node* field = fields[i];

        analyse_node(analyser, context, argument);

        if (!lookup::compare_type(context, field, argument, analyser.scope)) {
            String field_type    = lookup::get_type_name(context, field, analyser.scope);
            String argument_type = lookup::get_type_name(context, argument, analyser.scope);

            highlighter::error(context, argument.range.from, argument.range.to, "Expected type '%s', got '%s'", field_type, argument_type);
        }
    }
}

fn void traverse_access_module(Analyser* analyser, CompileContext* context, Node* node) => @pool() {
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
    if (!analyser.imports.contains(module_name)) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find module '%s', did you forget to import it?", module_name);
    }

    next = node;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            next = next.access_node.next;
        case NodeType.CALL:
            handle_call(analyser, context, next, full_name.str_view(), module_name, context.functions.get(full_name.str_view()) ?? null);

            @todo("move above block to separate function");

            next = null;
        default:
            highlighter::panic();
        }
    }

    if (!context.functions.has_key(full_name.str_view())) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find function '%s' in module '%s'", function_name, module_name);
    }
}

fn void traverse_access_variable(Analyser* analyser, CompileContext* context, Node* node) => @pool() {
    String        name          = node.access_node.name.path_node.path;
    VariableInfo* variable_info = scope::get_variable(analyser.scope, name);
    
    if (lookup::get_base_type_group(context, variable_info.node, analyser.scope) != "struct") {
        highlighter::panic();
    }

    String    type_name   = lookup::get_type_name(context, variable_info.node, analyser.scope);
    String    full_name   = string::tformat("%s.%s", analyser.module_name, type_name);
    TypeInfo* type_info   = context.types.get(full_name)!!;
    traverse_access_field(analyser, context, node, type_info);
}

fn void traverse_access_field(Analyser* analyser, CompileContext* context, Node* node, TypeInfo* type_info) => @pool() {
    String name = node.access_node.name.path_node.path;

    switch (node.access_node.next.type) {
    case NodeType.IDENT:
        break;
    default:
        highlighter::panic("traverse_access_field#access");
    }

    String   field_name = node.access_node.next.ident_node.name;
    NodeList fields     = lookup::get_type_fields(context, type_info, analyser.scope);
    String   field_type = lookup::get_type_name(context, node.access_node.name, analyser.scope);

    Node* field_node;
    foreach (Node* field : fields) {
        if (field.parameter_node.name.ident_node.name == field_name) {
            field_node = field;
            break;
        }
    }

    if (!field_node) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find field '%s' on type '%s'", field_name, field_type);
    }
}

fn bool always_returns(Analyser* analyser, CompileContext* context, Node* node) {
    switch (node.type) {
    case NodeType.RET:
        return true;
    case NodeType.FUNCTION:
        return compound_returns(analyser, context, node.function_node.statements);
    case NodeType.IF:
        bool then_returns    = compound_returns(analyser, context, node.if_node.then_statements);
        bool else_returns    = compound_returns(analyser, context, node.if_node.else_statements);
        bool else_if_returns = node.if_node.else_if ? always_returns(analyser, context, node.if_node.else_if) : true;

        return then_returns && else_returns && else_if_returns;
    default:
        return false;
    }
}

fn bool compound_returns(Analyser* analyser, CompileContext* context, NodeList statements)
{
    foreach (Node* statement : statements)
    {
        if (always_returns(analyser, context, statement)) {
            return true;
        }
    }

    return false;
}

fn void handle_call(Analyser* analyser, CompileContext* context, Node* node, String name, String module_name, FunctionInfo* function_info) {
    if (!function_info) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find function '%s' in module '%s'", name, module_name);
    }

    bool vaarg = false;

    int      min_parameters_len;
    NodeList parameters;
    
    switch (function_info.node.type) {
    case NodeType.FUNCTION:
        min_parameters_len = (int)function_info.node.function_node.parameters.len();
        parameters         = function_info.node.function_node.parameters;
    case NodeType.EXT:
        min_parameters_len = (int)function_info.node.ext_node.parameters.len();
        parameters         = function_info.node.ext_node.parameters;
    default:
        highlighter::panic();
    }

    foreach (int i, Node* parameter : parameters) {
        if (parameter.parameter_node.vaarg) {
            vaarg              = true;
            min_parameters_len = i;
            break;
        }
    }

    int arguments_len  = (int)node.call_node.arguments.len();
    int parameters_len = (int)parameters.len();
    
    if (arguments_len < min_parameters_len) {
        highlighter::note(context, function_info.node.range.from, function_info.node.range.to, "Definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Expected more arguments");
    }

    if (arguments_len > parameters_len) {
        if (!vaarg) {
            Node* argument = node.call_node.arguments[(long)arguments_len - 1];

            highlighter::error(context, argument.range.from, argument.range.to, "Expected less arguments");
        }
    }

    foreach (int i, Node* argument : node.call_node.arguments) {
        if (i >= parameters_len) {
            break;
        }

        Node* parameter = parameters[i];

        analyse_node(analyser, context, argument);

        if (parameter.parameter_node.vaarg) {
            continue;
        }

        if (!lookup::compare_type(context, parameter, argument, analyser.scope)) {
            String parameter_type = lookup::get_type_name(context, parameter, analyser.scope);
            String argument_type  = lookup::get_type_name(context, argument, analyser.scope);

            highlighter::error(context, argument.range.from, argument.range.to, "Expected type '%s', got '%s'", parameter_type, argument_type);
        }
    }
}

fn void free(Analyser* analyser, Allocator alloc) {
    scope::free(analyser.scope);
}
