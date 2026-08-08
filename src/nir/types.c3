module nir::types;

import std::collections::list;

alias StatementList = List{NirStatement*};
alias AttributeList = List{NirAttribute};
alias ParameterList = List{NirParameter};
alias ValueList     = List{NirValue*};

struct NirBuilder {
    Allocator     alloc;
    NirModule*    mod;
    NirStatement* current_function;
}

struct NirModule {
    StatementList statements;
    long          pc;
}

struct NirType {
    String name;
    // TODO: add base of sorts
}

struct NirAttribute {
    String name;
}

struct NirParameter {
    NirType type;
    String  name;
}

struct NirStatement {
    NirStatementKind kind;
    AttributeList    attributes;

    union {
        struct return_stmt {
            NirType   type;
            NirValue* value;
        }
        struct func_stmt {
            NirType type;
            String  name;
            ParameterList parameters;
            StatementList statements;
        }
        struct call_stmt {
            String    name;
            ValueList arguments;
        }
        struct reserve_stmt {
            NirType type;
            String  name;
        }
        struct store_stmt {
            NirStatement* destination;
            NirValue*     value;
            NirType       type;
        }
        struct read_stmt {
            NirType       type;
            String        name;
            NirStatement* source;
            NirType       source_type;
        }
        struct const_stmt {
            NirType   type;
            String    name;
            NirValue* value;
        }
    }
}

struct NirValue {
    NirValueKind kind;

    union {
        struct integer {
            NirType type;
            int     value;
        }
        struct reference {
            NirType       type;
            NirStatement* statement;
        }
        struct string {
            NirType type;
            String  value;
        }
    }
}

enum NirStatementKind {
    RETURN,
    FUNCTION,
    EXTERN,
    CALL,
    RESERVE,
    STORE,
    READ,
    CONST,

    EMPTY
}

enum NirValueKind {
    INT,
    REF,
    STRING,
}

constdef NirTypes : inline NirType {
    LOGIC    = { "log"    },
    ULOGIC   = { "ulog"   },
    INT_8    = { "i8"     },
    UINT_8   = { "u8"     },
    INT_32   = { "i32"    },
    UINT_32  = { "u32"    },
    INT_64   = { "i64"    },
    UINT_64  = { "u64"    },
    INT_128  = { "i128"   },
    UINT_128 = { "u128"   },
    VOID     = { "void"   },
    STRING   = { "string" },
}

constdef NirAttributes : inline NirAttribute {
    NO_RET = { "/nrt" },
    VA_ARG = { "/va"  },
    GLOBAL = { "/glb" },
}
