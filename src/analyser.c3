module nina::analyser;

import llvm;

import nina::util;
import nina::scope;
import nina::types;
import nina::lookup;
import nina::highlighter;

import std::collections::map;
import std::io;
import std::os;

fn Analyser* create(CompileContext* context, String path) {
    context.current_file   = path;

    Analyser* analyser = alloc::new(context.alloc, Analyser);
    String    mod      = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
    
    context.current_module = mod;

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
    case NodeType.MOD:         analyse_mod(analyser, context, node);
    case NodeType.FUNCTION:    analyse_function(analyser, context, node);
    case NodeType.TYPE:        analyse_type(analyser, context, node);
    case NodeType.RET:         analyse_ret(analyser, context, node, data);
    case NodeType.INT:         break;
    case NodeType.EXT:         analyse_ext(analyser, context, node);
    case NodeType.CALL:        analyse_call(analyser, context, node);
    case NodeType.BOOL:        break;
    case NodeType.STRING:      break;
    case NodeType.BIN:         analyse_bin(analyser, context, node, data);
    case NodeType.IDENT:       analyse_ident(analyser, context, node);
    case NodeType.VARIABLE:    analyse_variable(analyser, context, node);
    case NodeType.USE:         analyse_use(analyser, context, node);
    case NodeType.ACCESS:      analyse_access(analyser, context, node);
    case NodeType.UNARY:       analyse_unary(analyser, context, node);
    case NodeType.IF:          analyse_if(analyser, context, node, data);
    case NodeType.STRUCT:      analyse_struct(analyser, context, node);
    case NodeType.INIT:        analyse_init(analyser, context, node);
    case NodeType.NULL:        break;
    case NodeType.REFERENCE:   analyse_reference(analyser, context, node);
    case NodeType.DEREFERENCE: analyse_dereference(analyser, context, node);
    case NodeType.SUFFIX:      analyse_suffix(analyser, context, node);
    case NodeType.ASSIGN:      analyse_assign(analyser, context, node);
    case NodeType.WHILE:       analyse_while(analyser, context, node, data);
    case NodeType.REAL:        break;
    case NodeType.CHAR:        break;
    case NodeType.SWITCH:      analyse_switch(analyser, context, node, data);
    case NodeType.BREAK:       break;
    default:
        highlighter::panic("Missing analyser function for type '%s'", node.type);
    }
}

fn void analyse_mod(Analyser* analyser, CompileContext* context, Node* node) {
    String path = node.mod_node.path.path_node.path;

    if (context.mods.has_key(path)) {
        highlighter::error(
            context,
            context.current_file,
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

        highlighter::note(context, context.current_file, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Function '%s' already defined", name);
    }

    scope::add_function(analyser.scope, context.alloc, name, analyser.module_name, context.current_file, node);

    LookupElement lookup_data = lookup::get(context, node, analyser.scope);

    if (!always_returns(analyser, context, node) && lookup_data.type_name != "void")
    {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Missing return at end of function");
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

            highlighter::note(context, context.current_file, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, context.current_file, parameter.range.from, parameter.range.to, "Parameter '%s' already defined", parameter_name);
        }

        parameters.set(parameter_name, parameter);
        scope::add_variable(analyser.scope, context.alloc, parameter_name, parameter);
    }

    analyse_compound(analyser, context, node.function_node.statements, type);

    analyser.scope = analyser.scope.parent;

    parameters.free();
}

fn void analyse_type(Analyser* analyser, CompileContext* context, Node* node) => @pool() {
    String    name      = node.type_node.name.path_node.path;
    TypeInfo* type_info = lookup::get_type_info(context, name);

    if (!type_info) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find type '%s'", name);
    }

    String qualified_name = type_info.mod == ""
        ? type_info.name
        : string::tformat("%s.%s", type_info.mod, type_info.name);

    if (!type_info && qualified_name.contains(".") && !scope::get_imports(context.alloc, analyser.scope).contains(type_info.mod)) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find type '%s'", name);
    }
}

fn void analyse_ret(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    Node* function_type = (Node*)data;

    if (node.ret_node.value) {
        analyse_node(analyser, context, node.ret_node.value);

        if (!lookup::compare_type(context, function_type, node, analyser.scope)) {
            String expected_type = lookup::get(context, function_type, analyser.scope).type_name;
            String return_type   = lookup::get(context, node, analyser.scope).type_name;

            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Expected return type '%s', got '%s'", expected_type, return_type);
        }
    }
}

fn void analyse_ext(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.ext_node.type);

    String name = node.ext_node.name.ident_node.name;
    if (scope::has_function(analyser.scope, name)) {
        FunctionInfo* prev = scope::get_function(analyser.scope, name);
        
        highlighter::note(context, context.current_file, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Function '%s' already defined", name);
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

            highlighter::note(context, context.current_file, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, context.current_file, parameter.range.from, parameter.range.to, "Parameter '%s' already defined", parameter_name);
        }

        parameters.set(parameter_name, parameter);
    }
}

fn void analyse_call(Analyser* analyser, CompileContext* context, Node* node) {
    String        name          = node.call_node.name.path_node.path;
    FunctionInfo* function_info = lookup::get_function_info(context, name);

    handle_call(analyser, context, node, name, analyser.module_name, function_info);
}

fn void analyse_bin(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    analyse_node(analyser, context, node.bin_node.left, data);
    analyse_node(analyser, context, node.bin_node.right, data);

    LookupElement left  = lookup::get(context, node.bin_node.left, analyser.scope);
    LookupElement right = lookup::get(context, node.bin_node.right, analyser.scope);

    bool pointer_arith = (left.type_group == "pointer" && right.type_group == "integer")
        && (node.bin_node.operator.type == TokenType.PLUS || node.bin_node.operator.type == TokenType.MINUS);

    if (!pointer_arith && !lookup::compare_type(context, node.bin_node.left, node.bin_node.right, analyser.scope)) {

        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot operate type '%s' with type '%s'", left.type_name, right.type_name);
    }

    String group = left.type_group;
    String type  = left.type_name;

    switch (node.bin_node.operator.type) {
    case TokenType.PLUS:
    case TokenType.MINUS:
        if (group != "integer" && group != "pointer" && group != "real") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot use oprtator '%s' with type '%s'", node.bin_node.operator.value, type);
        }
    case TokenType.ASTERISK:
    case TokenType.SLASH:
    case TokenType.GTE:
    case TokenType.LTE:
    case TokenType.LANGLE:
    case TokenType.RANGLE:
        if (group != "integer" && group != "real") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot use oprtator '%s' with type '%s'", node.bin_node.operator.value, type);
        }
    case TokenType.IS_EQUAL:
    case TokenType.NOT_EQUAL:
        if (group == "struct") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot use oprtator '%s' with type '%s'", node.bin_node.operator.value, type);
        }
    default:
        break;
    }
}

fn void analyse_ident(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.ident_node.name;

    if (!scope::has_variable(analyser.scope, name)) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find variable '%s'", name);
    }

    scope::get_variable(analyser.scope, name).used = true;
}

fn void analyse_variable(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.variable_node.type);

    String name = node.variable_node.name.ident_node.name;

    if (name.starts_with("$")) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Variable names may not start with '$'");
    }

    if (lookup::get_type_info(context, name)) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Variable names may not be type names");
    }

    if (scope::has_variable(analyser.scope, name)) {
        VariableInfo* prev = scope::get_variable(analyser.scope, name);
        
        highlighter::note(context, context.current_file, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Variable '%s' already defined", name);
    }

    scope::add_variable(analyser.scope, context.alloc, name, node);

    if (node.variable_node.value) {
        analyse_node(analyser, context, node.variable_node.value);

        // get actual type infos and compare qualified names

        if (!lookup::compare_type(context, node, node.variable_node.value, analyser.scope)) {
            String variable_type = lookup::get(context, node, analyser.scope).type_name;
            String value_type    = lookup::get(context, node.variable_node.value, analyser.scope).type_name;

            highlighter::error(context, context.current_file, node.variable_node.value.range.from, node.variable_node.value.range.to, "Expected type '%s', got '%s'", variable_type, value_type);
        }
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
            highlighter::warn(context, context.current_file, statement.range.from, statement.range.to, "Statement will never be executed");
        }

        if (statement.type == NodeType.RET && index != statements.len() - 1)
        {
            returned = true;
            highlighter::note(context, context.current_file, statement.range.from, statement.range.to, "No statement will be executed after return");
        }
    }

    @todo("add usage module that tracks all usages per module and optimizes them away in codegen");

    analyser.scope.variables.@each(; String name, VariableInfo* info) {
        if (!info.used) {
            highlighter::warn(context, context.current_file, info.node.range.from, info.node.range.to, "Unused variable '%s'", name);
        }
    };
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
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find module '%s'", path);
    }

    analyser.imports.push(path);
    scope::add_import(analyser.scope, path);
}

fn void analyse_access(Analyser* analyser, CompileContext* context, Node* node) => @pool() {
    Node*  path = node.access_node.name;
    String name = path.path_node.path;

    if (scope::has_import(analyser.scope, name)) {
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
        String resolved_module   = scope::get_import(analyser.scope, short_module_name);

        if (resolved_module == "") {
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
                handle_call(analyser, context, next, resolved_full_name.str_view(), resolved_module, lookup::get_function_info(context, resolved_full_name.str_view()));

                next = null;
            default:
                highlighter::panic();
            }
        }

        if (!context.registry.functions.has_key(resolved_full_name.str_view())) {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find function '%s' in module '%s'", function_name, resolved_module);
        }

        return;
    }

    if (scope::has_variable(analyser.scope, name)) {
        scope::get_variable(analyser.scope, name).used = true;

        LookupElement base;

        if (scope::has_narrowed_type(analyser.scope, name)) {
            base = scope::get_narrowed_type(analyser.scope, name);
        } else {
            VariableInfo* variable_info = scope::get_variable(analyser.scope, name);
            base = lookup::get(context, variable_info.node, analyser.scope);
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

            FieldResult result = lookup::get_field(context, analyser.scope, base, field_name);

            if (result.field_node) {
                base = lookup::get(context, result.field_node, analyser.scope);
            } else if (result.lookup_element.type_name != "") {
                base = result.lookup_element;
            } else {
                highlighter::error(context, context.current_file, next.range.from, next.range.to, "Could not find field '%s' on type '%s'", field_name, base.type_name);
            }

            next = after;
        }
    } else if (lookup::get_type_info(context, name)) {
        TypeInfo*     type_info = lookup::get_type_info(context, name);
        LookupElement base      = { .llvm_type = type_info.llvm_type, .type_name = type_info.name };

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

            FieldResult result = lookup::get_field(context, analyser.scope, base, field_name);

            if (result.field_node) {
                base = lookup::get(context, result.field_node, analyser.scope);
            } else if (result.lookup_element.type_name != "") {
                base = result.lookup_element;
            } else {
                highlighter::error(context, context.current_file, next.range.from, next.range.to, "Could not find field '%s' on type '%s'", field_name, base.type_name);
            }

            next = after;
        }
    } else {
        highlighter::error(context, context.current_file, path.range.from, path.range.to, "Could not find '%s'", name);
    }
}

fn void analyse_unary(Analyser* analyser, CompileContext* context, Node* node) {
    LookupElement type_data = lookup::get(context, node, analyser.scope);
    String        type      = type_data.type_name;
    String        group     = type_data.type_group;

    switch (node.unary_node.operator.type) {
    case TokenType.PLUS:
    case TokenType.MINUS:
        if (group != "integer" && group != "real") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot use operator '%s' on type '%s'", node.unary_node.operator.value, type);
        }
    case TokenType.BANG:
        if (group != "boolean" && group != "pointer") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot use operator '%s' on type '%s'", node.unary_node.operator.value, type);
        }
    case TokenType.TILDA:
        if (group != "integer") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot use operator '%s' on type '%s'", node.unary_node.operator.value, type);
        }
    default:
        highlighter::panic();
    }
}

fn void analyse_if(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    analyse_node(analyser, context, node.if_node.condition);

    switch (lookup::get(context, node.if_node.condition, analyser.scope).type_group) {
    case "pointer":
    case "boolean":
        break;
    default:
        highlighter::error(context, context.current_file, node.if_node.condition.range.from, node.if_node.condition.range.to, "Expression must be a pointer or a bool");
    }

    analyser.scope = scope::create(context.alloc, analyser.scope);

    String narrowed_var;
    String narrowed_type;
    if (util::try_get_typeid_narrowing(node.if_node.condition, &narrowed_var, &narrowed_type)) {
        TypeInfo*   type_info = lookup::get_type_info(context, narrowed_type);
        LLVMTypeRef llvm_type = type_info.llvm_type;

        String type_group;

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

        scope::add_narrowed_type(analyser.scope, narrowed_var, {
            .llvm_type  = llvm_type,
            .type_name  = type_info.name,
            .type_group = type_group
        });
    }

    analyse_compound(analyser, context, node.if_node.then_statements, data);
    analyser.scope = analyser.scope.parent;

    analyser.scope = scope::create(context.alloc, analyser.scope);
    analyse_compound(analyser, context, node.if_node.else_statements, data);
    analyser.scope = analyser.scope.parent;

    if (node.if_node.else_if) {
        analyse_node(analyser, context, node.if_node.else_if, data);
    }
}

fn void analyse_struct(Analyser* analyser, CompileContext* context, Node* node) => @pool() {
    String name = node.struct_node.name.ident_node.name;

    if (scope::has_type(analyser.scope, name)) {
        TypeInfo* prev = scope::get_type(analyser.scope, name);
        
        highlighter::note(context, prev.file, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Type '%s' already defined", name);
    }

    scope::add_type(analyser.scope, context.alloc, name, analyser.module_name, context.current_file, node);

    HashMap{String, Node*} fields;
    fields.tinit();

    foreach (Node* field : node.struct_node.fields) {
        analyse_node(analyser, context, field.parameter_node.type);

        String field_name = field.parameter_node.name.ident_node.name;

        if (fields.has_key(field_name)) {
            Node* prev = fields.get(field_name)!!;

            highlighter::note(context, context.current_file, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, context.current_file, field.range.from, field.range.to, "Field '%s' already defined", field_name);
        }

        fields.set(field_name, field);
    }
}

fn void analyse_init(Analyser* analyser, CompileContext* context, Node* node) {
    String    name      = node.struct_node.name.path_node.path;
    TypeInfo* type_info = lookup::get_type_info(context, name);

    if (!type_info) {
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find type '%s'", name);
    }

    NodeList fields = type_info.node.struct_node.fields;

    int arguments_len = (int)node.init_node.arguments.len();
    int fields_len    = (int)fields.len();
    
    if (arguments_len < fields_len) {
        highlighter::note(context, type_info.file, type_info.node.range.from, type_info.node.range.to, "Definition was here");
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Expected more arguments");
    }

    if (arguments_len > fields_len) {
        Node* argument = node.init_node.arguments[(long)arguments_len - 1];

        highlighter::error(context, context.current_file, argument.range.from, argument.range.to, "Expected less arguments");
    }

    foreach (int i, Node* argument : node.init_node.arguments) {
        if (i >= fields_len) {
            break;
        }

        Node* field = fields[i];

        analyse_node(analyser, context, argument);

        if (!lookup::compare_type(context, field, argument, analyser.scope)) {
            String field_type    = lookup::get(context, field, analyser.scope).type_name;
            String argument_type = lookup::get(context, argument, analyser.scope).type_name;

            highlighter::error(context, context.current_file, argument.range.from, argument.range.to, "Expected type '%s', got '%s'", field_type, argument_type);
        }
    }
}

fn void analyse_reference(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.reference_node.node);
}

fn void analyse_dereference(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.reference_node.node);

    if (lookup::get(context, node.dereference_node.node, analyser.scope).type_group != "pointer") {
        String type_name = lookup::get(context, node, analyser.scope).type_name;

        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot dereference value of type '%s'", type_name);
    }
}

fn void analyse_suffix(Analyser* analyser, CompileContext* context, Node* node) {
    String base_group = lookup::get(context, node.suffix_node.node, analyser.scope).type_group;

    switch (node.suffix_node.operator.type) {
    case TokenType.PLUS:
    case TokenType.MINUS:
        if (base_group != "integer" && base_group != "pointer") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot apply operator '%s' to type group '%s'", node.suffix_node.operator.value, base_group);
        }
    case TokenType.BANG:
        if (base_group != "boolean") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot apply operator '%s' to type group '%s'", node.suffix_node.operator.value, base_group);
        }
    default:
        highlighter::panic();
    }
}

fn void analyse_assign(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.assign_node.node, null);
    analyse_node(analyser, context, node.assign_node.expr, null);

    if (!lookup::compare_type(context, node.assign_node.node, node.assign_node.expr, analyser.scope)) {
        String target_type = lookup::get(context, node.assign_node.node, analyser.scope).type_name;
        String expr_type   = lookup::get(context, node.assign_node.expr, analyser.scope).type_name;

        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Cannot assign type '%s' to type '%s'", expr_type, target_type);
    }
}

fn void analyse_while(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    analyse_node(analyser, context, node.while_node.expr);

    switch (lookup::get(context, node.if_node.condition, analyser.scope).type_group) {
    case "pointer":
    case "boolean":
        break;
    default:
        highlighter::error(context, context.current_file, node.if_node.condition.range.from, node.if_node.condition.range.to, "Expression must be a pointer or a bool");
    }

    analyser.scope = scope::create(context.alloc, analyser.scope);
    analyse_compound(analyser, context, node.while_node.statements, data);
    analyser.scope = analyser.scope.parent;
}

fn void analyse_switch(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    analyse_node(analyser, context, node.switch_node.expr);

    foreach (Node* case_node : node.switch_node.cases) {
        switch (case_node.type) {
        case NodeType.CASE:
            analyse_node(analyser, context, case_node.case_node.expr);

            if (!lookup::compare_type(context, node.switch_node.expr, case_node.case_node.expr, analyser.scope)) {
                String subject_type = lookup::get(context, node.switch_node.expr, analyser.scope).type_name;
                String case_type    = lookup::get(context, case_node.case_node.expr, analyser.scope).type_name;

                highlighter::error(context, context.current_file, case_node.case_node.expr.range.from, case_node.case_node.expr.range.to, "Expected type '%s', got '%s'", subject_type, case_type);
            }

            analyser.scope = scope::create(context.alloc, analyser.scope);

            String narrowed_var;
            String narrowed_type;
            if (util::try_get_typeid_narrowing_switch(node.switch_node.expr, case_node.case_node.expr, &narrowed_var, &narrowed_type)) {
                TypeInfo*   type_info = lookup::get_type_info(context, narrowed_type);
                LLVMTypeRef llvm_type = type_info.llvm_type;
                String      type_group;

                switch (llvm::get_type_kind(llvm_type)) {
                case LLVMTypeKind.INTEGER_TYPE_KIND:
                    type_group = llvm::get_int_type_width(llvm_type) == 1 ? "boolean" : "integer";
                case LLVMTypeKind.POINTER_TYPE_KIND:
                    type_group = "pointer";
                case LLVMTypeKind.STRUCT_TYPE_KIND:
                    type_group = "struct";
                case LLVMTypeKind.DOUBLE_TYPE_KIND:
                    type_group = "real";
                default:
                    highlighter::panic();
                }

                scope::add_narrowed_type(analyser.scope, narrowed_var, {
                    .llvm_type  = llvm_type,
                    .type_name  = type_info.name,
                    .type_group = type_group
                });
            }

            analyse_compound(analyser, context, case_node.case_node.statements, data);

            analyser.scope = analyser.scope.parent;
        case NodeType.DEFAULT:
            analyser.scope = scope::create(context.alloc, analyser.scope);
            analyse_compound(analyser, context, case_node.default_node.statements, data);
            analyser.scope = analyser.scope.parent;
        default:
            highlighter::panic();
        }
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
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find function '%s' in module '%s'", name, module_name);
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
        highlighter::note(context, function_info.file, function_info.node.range.from, function_info.node.range.to, "Definition was here");
        highlighter::error(context, context.current_file, node.range.from, node.range.to, "Expected more arguments");
    }

    if (arguments_len > parameters_len) {
        if (!vaarg) {
            Node* argument = node.call_node.arguments[(long)arguments_len - 1];

            highlighter::error(context, context.current_file, argument.range.from, argument.range.to, "Expected less arguments");
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
            String parameter_type = lookup::get(context, parameter, analyser.scope).type_name;
            String argument_type  = lookup::get(context, argument, analyser.scope).type_name;

            highlighter::error(context, context.current_file, argument.range.from, argument.range.to, "Expected type '%s', got '%s'", parameter_type, argument_type);
        }
    }
}

fn void free(Analyser* analyser, Allocator alloc) {
    scope::free(analyser.scope);
}
