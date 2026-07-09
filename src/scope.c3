module nina::scope;

import llvm;

import nina::types;

fn Scope* create(Allocator alloc, Scope* parent = null) {
    Scope* scope = alloc::new(alloc, Scope);

    scope.parent = parent;
    scope.functions.init(alloc);
    scope.variables.init(alloc);
    scope.types.init(alloc);

    return scope;
}

// -- VARIABLE --

fn void add_variable(Scope* scope, Allocator alloc, String name, Node* node, LLVMTypeRef llvm_type = null, LLVMValueRef llvm_value = null) {
    VariableInfo* variable = alloc::new(alloc, VariableInfo);

    variable.name       = name;
    variable.node       = node;
    variable.llvm_type  = llvm_type;
    variable.llvm_value = llvm_value;

    scope.variables.set(name, variable);
}

fn bool has_variable(Scope* scope, String name) {
    if (scope.variables.has_key(name)) {
        return true;
    }

    if (scope.parent) {
        return has_variable(scope.parent, name);
    }

    return false;
}

fn VariableInfo* get_variable(Scope* scope, String name) {
    if (scope.variables.has_key(name)) {
        return scope.variables.get(name)!!;
    }

    if (scope.parent) {
        return get_variable(scope.parent, name);
    }

    return null;
}

// -- FUNCTION --

fn FunctionInfo* add_function(Scope* scope, Allocator alloc, String name, String mod, String file, Node* node, LLVMTypeRef llvm_type = null, LLVMValueRef llvm_value = null) {
    FunctionInfo* function = alloc::new(alloc, FunctionInfo);

    function.mod        = mod;
    function.file       = file;
    function.node       = node;
    function.llvm_type  = llvm_type;
    function.llvm_value = llvm_value;

    scope.functions.set(name, function);

    return function;
}

fn bool has_function(Scope* scope, String name) {
    if (scope.functions.has_key(name)) {
        return true;
    }

    if (scope.parent) {
        return has_function(scope.parent, name);
    }

    return false;
}

fn FunctionInfo* get_function(Scope* scope, String name) {
    if (scope.functions.has_key(name)) {
        return scope.functions.get(name)!!;
    }

    if (scope.parent) {
        return get_function(scope.parent, name);
    }

    return null;
}

// -- TYPE --
fn void add_type(Scope* scope, Allocator alloc, String name, String mod, String file, Node* node, LLVMTypeRef llvm_type = null, LLVMValueRef llvm_value = null) {
    TypeInfo* type = alloc::new(alloc, TypeInfo);

    type.mod        = mod;
    type.file       = file;
    type.node       = node;
    type.llvm_type  = llvm_type;
    type.llvm_value = llvm_value;

    scope.types.set(name, type);
}

fn bool has_type(Scope* scope, String name) {
    if (scope.types.has_key(name)) {
        return true;
    }

    if (scope.parent) {
        return has_type(scope.parent, name);
    }

    return false;
}

fn TypeInfo* get_type(Scope* scope, String name) {
    if (scope.types.has_key(name)) {
        return scope.types.get(name)!!;
    }

    if (scope.parent) {
        return get_type(scope.parent, name);
    }

    return null;
}

fn void free(Scope* scope) {
    if (scope == null) {
        return;
    }
    free(scope.parent);

    scope.functions.free();
}
