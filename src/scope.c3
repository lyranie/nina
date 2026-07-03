module nina::scope;

import llvm;

import nina::types;

fn Scope* create(Allocator alloc, Scope* parent = null) {
    Scope* scope = alloc::new(alloc, Scope);

    scope.parent = parent;
    scope.functions.init(alloc);
    scope.variables.init(alloc);

    return scope;
}

fn void add_variable(Scope* scope, Allocator alloc, String name, Node* node, LLVMTypeRef llvm_type = null, LLVMValueRef llvm_value = null) {
    VariableInfo* variable = alloc::new(alloc, VariableInfo);

    variable.name       = name;
    variable.node       = node;
    variable.llvm_type  = llvm_type;
    variable.llvm_value = llvm_value;

    scope.variables.set(name, variable);
}

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

fn void free(Scope* scope) {
    if (scope == null) {
        return;
    }
    free(scope.parent);

    scope.functions.free();
}
