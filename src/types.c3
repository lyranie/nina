module nina::types;

import llvm;

import std::collections::list;
import std::collections::map;
import std::time;

alias TokenList  = List{Token};
alias StringList = List{String};
alias NodeList   = List{Node*};

const Token TOKEN_EMPTY = {};

// -- ARGS --

struct Args {
    CompileCommand cmd;
    StringList     files;
    bool           emit_ir;
    bool           no_libc;
    bool           no_debug;
    bool           no_linker;
    String         output;
}

enum CompileCommand {
    NONE,
    COMPILE,
    COMPILE_RUN
}

// -- COMPILER --

struct CompileContext {
    Allocator                      alloc;
    Profiler*                      profiler;
    Args*                          args;
    HashMap{String, String}        mods;
    String                         current_file;
    Lookup*                        lookup;
    HashMap{String, Node*}         trees;
    HashMap{String, FunctionInfo*} functions;
    HashMap{String, LLVMModuleRef} modules;
}

struct Range {
    int line;
    int column;
}

struct Lexer {
    String filepath;
    String content;
    char   current;
    int    cursor;
    Range  range;

    // context fields
    struct context {
        TokenList tokens;
    }
}

struct Token {
    TokenType type;
    String    value;

    struct range {
        Range start;
        Range end;
    }
    void* data;
}

enum TokenType {
    EOF,
    IDENT,
    INT,
    REAL,
    STRING,
    TRUE,
    FALSE,
    NUL,

    KW_MOD,
    KW_RET,
    KW_EXT,
    KW_USE,

    SEMI,
    LPAREN,
    RPAREN,
    LBRACE,
    RBRACE,
    LBRACKET,
    RBRACKET,
    ASTERISK,
    EQUALS,
    PERIOD,
    COMMA,
    PLUS,
    MINUS,
    SLASH,
    AMP,
    ELLIPSE,
    AND,
    OR,
    IS_EQUAL,
    NOT_EQUAL,
    GTE,
    LTE,
    LANGLE,
    RANGLE,
}

struct Parser {
    int   cursor;
    Token current;

    struct context {
        Node* ast;
    }
}

struct Node {
    NodeType type;
    struct range {
        Range from;
        Range to;
    }

    union {
        struct mod_node {
            Node*    path;
            NodeList statements;
        }
        struct path_node {
            String path;
        }
        struct type_node {
            Node*  name;
            String suffix;
        }
        struct ident_node {
            String name;
        }
        struct parameter_node {
            Node* type;
            Node* name;
            bool  vaarg;
        }
        struct ret_node {
            Node* value;
        }
        struct function_node {
            Node*    type;
            Node*    name;
            NodeList parameters;
            NodeList statements;
        }
        struct bin_node {
            Token operator;
            Node* left;
            Node* right;
        }
        struct int_node {
            String number;
        }
        struct ext_node {
            Node*    type;
            Node*    name;
            NodeList parameters;
        }
        struct call_node {
            Node*    name;
            NodeList arguments;
        }
        struct bool_node {
            String value;
        }
        struct string_node {
            String string;
        }
        struct variable_node {
            Node* type;
            Node* name;
            Node* value;
        }
        struct use_node {
            Node* path;
        }
        struct access_node {
            Node* name;
            Node* next;
        }
    }
}

enum NodeType {
    MOD,
    PATH,
    TYPE,
    IDENT,
    PARAMETER,
    RET,
    FUNCTION,
    BIN,
    INT,
    EXT,
    CALL,
    BOOL,
    STRING,
    VARIABLE,
    USE,
    ACCESS,
}

struct Analyser {
    Scope*     scope;
    String     module_name;
    StringList imports;
}

struct Scope {
    Scope*                         parent;
    HashMap{String, FunctionInfo*} functions;
    HashMap{String, VariableInfo*} variables;
}

struct FunctionInfo {
    String       mod;
    String       file;
    Node*        node;
    LLVMTypeRef  llvm_type;
    LLVMValueRef llvm_value;
}

struct VariableInfo {
    String       name;
    Node*        node;
    LLVMTypeRef  llvm_type;
    LLVMValueRef llvm_value;
}

struct Lookup {
    inline HashMap{String, Type*} types;
}

struct Type {
    String      name;
    String      filepath;
    Node*       node;
    LLVMTypeRef llvm_type;
}

struct Generator {
    String           module_name;
    Scope*           scope;
    LLVMModuleRef    llvm_module;
    LLVMBuilderRef   llvm_builder;
    LLVMDIBuilderRef llvm_debug_builder;
    LLVMMetadataRef  llvm_debug_file;
}

struct Linker {
    TargetOS   target_os;
    TargetArch target_arch;
    String     output;
}

enum TargetOS {
    UNKNOWN,
    LINUX,
}

enum TargetArch {
    UNKNOWN,
    X86_64,
}

// -- PROFILER --
struct ProfilerStage {
    String name;
    double elapsed;
}

struct Profiler {
    List{ProfilerStage} stages;
    Time                start;
}
