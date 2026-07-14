module nina::parser;

import nina::core;
import nina::util;
import nina::types;
import nina::highlighter;

import std::collections::list;
import std::io;
import std::os;

fn Parser* create(Allocator alloc, Lexer* lexer) {
    Parser* parser = alloc::new(alloc, Parser);

    parser.current     = lexer.context.tokens.get(0);
    parser.context.ast = alloc::new(alloc, Node);

    return parser;
}

fn void parse(Parser* parser, CompileContext* context, Lexer* lexer) {
    if (parser.current.type != TokenType.EOF) {
        parse_mod(parser, context, lexer);
    }

    context.trees.set(context.current_file, parser.context.ast);
}

fn void parse_mod(Parser* parser, CompileContext* context, Lexer* lexer) {
    consume(parser, context, lexer, TokenType.KW_MOD);

    Node* path = parse_path(parser, context, lexer);
    consume(parser, context, lexer, TokenType.SEMI);

    List{Node*} statements;
    statements.init(context.alloc);

    while (parser.current.type != TokenType.EOF) {
        switch (parser.current.type) {
        case TokenType.IDENT:   statements.push(parse_function(parser, context, lexer));
        case TokenType.KW_EXT:  statements.push(parse_ext(parser, context, lexer));
        case TokenType.KW_USE:  statements.push(parse_use(parser, context, lexer));
        case TokenType.KW_TYPE: statements.push(parse_struct(parser, context, lexer));
        case TokenType.KW_BASE: statements.push(parse_base(parser, context, lexer));
        default:
            highlighter::error(context, context.current_file, parser.current.range.start, parser.current.range.end, "Statement expected, got '%s'", parser.current.type);
        }
    }

    consume(parser, context, lexer, TokenType.EOF);

    parser.context.ast.type                = NodeType.MOD;
    parser.context.ast.mod_node.path       = path;
    parser.context.ast.mod_node.statements = statements;

    statements.free();
}

fn Node* parse_path(Parser* parser, CompileContext* context, Lexer* lexer) => @pool() {
    Range start = parser.current.range.start;

    DString path;
    path.tinit();

    path.append(parser.current.value);
    consume(parser, context, lexer, TokenType.IDENT);

    while (parser.current.type == TokenType.PERIOD) {
        path.append(".");
        consume(parser, context, lexer, TokenType.PERIOD);

        path.append(parser.current.value);
        consume(parser, context, lexer, TokenType.IDENT);
    }

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.PATH, start, end; node) {
        node.path_node.path = path.copy_str(context.alloc);
    };
}

fn Node* parse_function(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    FunctionSignature sig        = parse_function_signature(parser, context, lexer);
    NodeList          statements = parse_compound(parser, context, lexer);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.FUNCTION, start, end; node) {
        node.function_node.type       = sig.type;
        node.function_node.name       = sig.name;
        node.function_node.parameters = sig.parameters;
        node.function_node.statements = statements;
    };
}

fn Node* parse_type(Parser* parser, CompileContext* context, Lexer* lexer) => @pool() {
    Range start = parser.current.range.start;
    Node* name  = parse_path(parser, context, lexer);

    DString suffix;
    suffix.tinit();

    while (parser.current.type == TokenType.ASTERISK || parser.current.type == TokenType.LBRACKET)
    {
        switch (parser.current.type)
        {
        case TokenType.ASTERISK:
            suffix.append('*');
            consume(parser, context, lexer, TokenType.ASTERISK);
        case TokenType.LBRACKET:
            suffix.append("[]");
            consume(parser, context, lexer, TokenType.LBRACKET);
            consume(parser, context, lexer, TokenType.RBRACKET);
        default:
            highlighter::panic();
        }
    }

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.TYPE, start, end; node) {
        node.type_node.name   = name;
        node.type_node.suffix = suffix.copy_str(context.alloc);
    };
}

fn Node* parse_identifier(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range  start = parser.current.range.start;
    String name  = parser.current.value;

    consume(parser, context, lexer, TokenType.IDENT);
    
    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.IDENT, start, end; node) {
        node.ident_node.name = name;
    };
}

fn NodeList parse_parameters(Parser* parser, CompileContext* context, Lexer* lexer) {
    NodeList parameters;
    parameters.init(context.alloc);

    consume(parser, context, lexer, TokenType.LPAREN);

    if (parser.current.type != TokenType.RPAREN) {
        parameters.push(parse_parameter(parser, context, lexer));

        while (parser.current.type == TokenType.COMMA) {
            consume(parser, context, lexer, TokenType.COMMA);
            parameters.push(parse_parameter(parser, context, lexer));
        }
    }

    consume(parser, context, lexer, TokenType.RPAREN);

    return parameters;
}

fn Node* parse_parameter(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;
    Node* type  = null;

    if (starts_type(peek(parser, lexer).type)) {
        type = parse_type(parser, context, lexer);
    }

    Node* name = parse_identifier(parser, context, lexer);
    bool  vaarg;

    if (parser.current.type == TokenType.ELLIPSE) {
        vaarg = true;
        consume(parser, context, lexer, TokenType.ELLIPSE);
    }

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.PARAMETER, start, end; node) {
        node.parameter_node.type  = type;
        node.parameter_node.name  = name;
        node.parameter_node.vaarg = vaarg;
    };
}

fn NodeList parse_compound(Parser* parser, CompileContext* context, Lexer* lexer) {
    NodeList statements;
    statements.init(context.alloc);

    consume(parser, context, lexer, TokenType.LBRACE);
    
    while (parser.current.type != TokenType.RBRACE) {
        switch (parser.current.type) {
        case TokenType.KW_RET:   statements.push(parse_ret(parser, context, lexer));
        case TokenType.IDENT:    statements.push(parse_identifier_statement(parser, context, lexer));
        case TokenType.KW_IF:    statements.push(parse_if(parser, context, lexer));
        case TokenType.ASTERISK: statements.push(parse_assign_or_expr_statement(parser, context, lexer));
        case TokenType.KW_WHILE: statements.push(parse_while(parser, context, lexer));
        default:
            highlighter::error(context, context.current_file, parser.current.range.start, parser.current.range.end, "Statement expected, got '%s'", parser.current.type);
        }
    }

    consume(parser, context, lexer, TokenType.RBRACE);

    return statements;
}

fn Node* parse_ret(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_RET);

    Node* value = null;
    if (parser.current.type != TokenType.SEMI) {
        value = parse_expr(parser, context, lexer);
    }

    consume(parser, context, lexer, TokenType.SEMI);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.RET, start, end; node) {
        node.ret_node.value = value;
    };
}

fn Node* parse_expr(Parser* parser, CompileContext* context, Lexer* lexer) {
    return parse_binary(parser, context, lexer, 1);
}

fn Node* parse_binary(Parser* parser, CompileContext* context, Lexer* lexer, int min_prec) {
    Node* node = parse_factor(parser, context, lexer);

    while (true) {
        int prec = util::precedence(parser.current.type);
        if (prec == 0 || prec < min_prec) {
            break;
        }

        Token operator = parser.current;
        consume(parser, context, lexer, operator.type);

        Node* left  = clone_node(context, node);
        Node* right = parse_binary(parser, context, lexer, prec + 1);

        node = @make_node(context, NodeType.BIN, left.range.from, right.range.to; _node) {
            _node.bin_node.operator = operator;
            _node.bin_node.left     = left;
            _node.bin_node.right    = right;
        };
    }

    return node;
}

fn Node* parse_factor(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = null;

    switch (parser.current.type) {
    case TokenType.INT:    node = parse_int(parser, context, lexer);
    case TokenType.TRUE:
    case TokenType.FALSE:  node = parse_bool(parser, context, lexer);
    case TokenType.STRING: node = parse_string(parser, context, lexer);
    case TokenType.IDENT:  node = parse_identifier_expr(parser, context, lexer);
    case TokenType.LPAREN:
        Range start = parser.current.range.start;
        consume(parser, context, lexer, TokenType.LPAREN);

        node = parse_expr(parser, context, lexer);
        node.range.from = start;
        node.range.to   = parser.current.range.end;

        consume(parser, context, lexer, TokenType.RPAREN);
    case TokenType.PLUS:
    case TokenType.MINUS:    node = parse_unary(parser, context, lexer);
    case TokenType.KW_NEW:   node = parse_init(parser, context, lexer);
    case TokenType.NULL:     node = parse_null(parser, context, lexer);
    case TokenType.AMP:      node = parse_reference(parser, context, lexer);
    case TokenType.ASTERISK: node = parse_dereference(parser, context, lexer);
    case TokenType.REAL:     node = parse_real(parser, context, lexer);
    default:
        highlighter::error(context, context.current_file, parser.current.range.start, parser.current.range.end, "Expression expected, got '%s'", parser.current.type);
    }

    node = try_parse_suffix(parser, context, lexer, node);

    return node;
}

fn Node* parse_int(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;
    Range end   = parser.current.range.end;

    String number = parser.current.value;

    consume(parser, context, lexer, TokenType.INT);

    return @make_node(context, NodeType.INT, start, end; node) {
        node.int_node.number = number;
    };
}

fn Node* parse_ext(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_EXT);

    FunctionSignature sig = parse_function_signature(parser, context, lexer);

    consume(parser, context, lexer, TokenType.SEMI);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.EXT, start, end; node) {
        node.ext_node.type       = sig.type;
        node.ext_node.name       = sig.name;
        node.ext_node.parameters = sig.parameters;
    };
}

fn Node* parse_identifier_statement(Parser* parser, CompileContext* context, Lexer* lexer) {
    Mark mark_start = save(parser);

    switch (peek(parser, lexer).type) {
    case TokenType.LPAREN:
        Node* node = parse_call(parser, context, lexer);

        consume(parser, context, lexer, TokenType.SEMI);

        return node;
    case TokenType.PERIOD:
        if (is_qualified_type_ident(parser, context, lexer)) {
            return parse_variable(parser, context, lexer);
        }

        restore(parser, mark_start);

        return parse_assign_or_expr_statement(parser, context, lexer);
    case TokenType.EQUALS:
        return parse_assign_or_expr_statement(parser, context, lexer);
    case TokenType.PLUS:
    case TokenType.MINUS:
    case TokenType.BANG:
        return parse_assign_or_expr_statement(parser, context, lexer);
    default:
        return parse_variable(parser, context, lexer);
    }
}

fn Node* parse_call(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    Node*    path      = parse_path(parser, context, lexer);
    NodeList arguments = parse_arguments(parser, context, lexer);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.CALL, start, end; node) {
        node.call_node.name      = path;
        node.call_node.arguments = arguments;
    };
}

fn NodeList parse_arguments(Parser* parser, CompileContext* context, Lexer* lexer) {
    NodeList arguments;
    arguments.init(context.alloc);

    consume(parser, context, lexer, TokenType.LPAREN);
    
    if (parser.current.type != TokenType.RPAREN) {
        arguments.push(parse_expr(parser, context, lexer));

        while (parser.current.type == TokenType.COMMA) {
            consume(parser, context, lexer, TokenType.COMMA);

            arguments.push(parse_expr(parser, context, lexer));
        }
    }

    consume(parser, context, lexer, TokenType.RPAREN);

    return arguments;
}

fn Node* parse_bool(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;
    Range end   = parser.current.range.end;

    String value = parser.current.value;

    consume(parser, context, lexer, parser.current.type);

    return @make_node(context, NodeType.BOOL, start, end; node) {
        node.bool_node.value = value;
    };
}

fn Node* parse_string(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;
    Range end   = parser.current.range.end;

    String string = parser.current.value;

    consume(parser, context, lexer, TokenType.STRING);

    return @make_node(context, NodeType.STRING, start, end; node) {
        node.string_node.string = string;
    };
}

fn Node* parse_identifier_expr(Parser* parser, CompileContext* context, Lexer* lexer) {
    switch (peek(parser, lexer).type) {
    case TokenType.LPAREN:
        return parse_call(parser, context, lexer);
    case TokenType.PERIOD:
        return parse_access(parser, context, lexer);
    default:
        return parse_identifier(parser, context, lexer);
    }
}

fn Node* parse_variable(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    Node* type = parse_type(parser, context, lexer);
    Node* name = parse_identifier(parser, context, lexer);

    Node* value = null;
    if (parser.current.type == TokenType.EQUALS) {
        consume(parser, context, lexer, TokenType.EQUALS);

        value = parse_expr(parser, context, lexer);
    }

    consume(parser, context, lexer, TokenType.SEMI);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.VARIABLE, start, end; node) {
        node.variable_node.type  = type;
        node.variable_node.name  = name;
        node.variable_node.value = value;
    };
}

fn Node* parse_use(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_USE);

    Node* path = parse_path(parser, context, lexer);

    consume(parser, context, lexer, TokenType.SEMI);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.USE, start, end; node) {
        node.use_node.path = path;
    };
}

fn Node* parse_access(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;
    Node* name  = parse_identifier(parser, context, lexer);

    consume(parser, context, lexer, TokenType.PERIOD);

    Node* next = parse_identifier_expr(parser, context, lexer);
    Range end  = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.ACCESS, start, end; node) {
        node.access_node.name = name;
        node.access_node.next = next;
    };
}

fn Node* parse_unary(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    Token operator = parser.current;
    consume(parser, context, lexer, operator.type);

    Node* expr = parse_expr(parser, context, lexer);
    Range end  = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.UNARY, start, end; node) {
        node.unary_node.operator = operator;
        node.unary_node.node     = expr;
    };
}

fn Node* parse_if(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_IF);
    consume(parser, context, lexer, TokenType.LPAREN);

    Node* condition = parse_expr(parser, context, lexer);
    
    consume(parser, context, lexer, TokenType.RPAREN);

    NodeList then_statements = parse_compound(parser, context, lexer);

    NodeList else_statements;
    Node*    else_if         = null;

    if (parser.current.type == TokenType.KW_ELSE) {
        consume(parser, context, lexer, TokenType.KW_ELSE);

        switch (parser.current.type) {
        case TokenType.KW_IF:
            else_if = parse_if(parser, context, lexer);
        default:
            else_statements = parse_compound(parser, context, lexer);
        }
    }

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.IF, start, end; node) {
        node.if_node.condition       = condition;
        node.if_node.then_statements = then_statements;
        node.if_node.else_statements = else_statements;
        node.if_node.else_if         = else_if;
    };
}

fn Node* parse_struct(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_TYPE);
    
    Node*    name   = parse_identifier(parser, context, lexer);
    NodeList fields = parse_fields(parser, context, lexer);

    Node* base = null;
    if (parser.current.type == TokenType.COLON) {
        consume(parser, context, lexer, TokenType.COLON);

        base = parse_path(parser, context, lexer);
    }

    consume(parser, context, lexer, TokenType.SEMI);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.STRUCT, start, end; node) {
        node.struct_node.name   = name;
        node.struct_node.fields = fields;
        node.struct_node.base   = base;
    };
}

fn NodeList parse_fields(Parser* parser, CompileContext* context, Lexer* lexer) {
    NodeList fields;
    fields.init(context.alloc);

    consume(parser, context, lexer, TokenType.LPAREN);

    if (parser.current.type != TokenType.RPAREN) {
        fields.push(parse_field(parser, context, lexer));

        while (parser.current.type == TokenType.COMMA) {
            consume(parser, context, lexer, TokenType.COMMA);
            fields.push(parse_field(parser, context, lexer));
        }
    }

    consume(parser, context, lexer, TokenType.RPAREN);

    return fields;
}

fn Node* parse_field(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;
    Node* type  = parse_type(parser, context, lexer);
    Node* name  = parse_identifier(parser, context, lexer);
    Range end   = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.PARAMETER, start, end; node) {
        node.parameter_node.type = type;
        node.parameter_node.name = name;
    };
}

fn Node* parse_init(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_NEW);

    Node*    name      = parse_path(parser, context, lexer);
    NodeList arguments = parse_arguments(parser, context, lexer);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.INIT, start, end; node) {
        node.init_node.name      = name;
        node.init_node.arguments = arguments;
    };
}

fn Node* parse_null(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.NULL);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.NULL, start, end; node) {};
}

fn Node* parse_reference(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.AMP);

    Node* expr = parse_expr(parser, context, lexer);
    Range end  = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.REFERENCE, start, end; node) {
        node.reference_node.node = expr;
    };
}

fn Node* parse_dereference(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.ASTERISK);

    Node* expr = parse_factor(parser, context, lexer);
    Range end  = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.DEREFERENCE, start, end; node) {
        node.dereference_node.node = expr;
    };
}

fn Node* try_parse_suffix(Parser* parser, CompileContext* context, Lexer* lexer, Node* node) {
    if ((parser.current.type == TokenType.PLUS  ||
        parser.current.type == TokenType.MINUS ||
        parser.current.type == TokenType.BANG) &&
        peek(parser, lexer).type == parser.current.type) {
        Token operator = parser.current;

        consume(parser, context, lexer, operator.type);
        consume(parser, context, lexer, operator.type);

        operator.value = string::format(context.alloc, "%s%s", operator.value, operator.value);
        operator.range.end.column++;

        Range start = node.range.from;
        Range end   = operator.range.end;

        Node* expr = clone_node(context, node);

        node = @make_node(context, NodeType.SUFFIX, start, end; _node) {
            _node.suffix_node.operator = operator;
            _node.suffix_node.node     = expr;
        };
    }

    return node;
}

fn Node* parse_assign_or_expr_statement(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start  = parser.current.range.start;
    Node* target = parse_expr(parser, context, lexer);

    if (parser.current.type == TokenType.EQUALS) {
        consume(parser, context, lexer, TokenType.EQUALS);

        Node* expr = parse_expr(parser, context, lexer);
        Range end  = parser.current.range.end;

        consume(parser, context, lexer, TokenType.SEMI);

        return @make_node(context, NodeType.ASSIGN, start, end; node) {
            node.assign_node.node = target;
            node.assign_node.expr = expr;
        };
    }

    target = try_parse_suffix(parser, context, lexer, target);
    consume(parser, context, lexer, TokenType.SEMI);

    return target;
}

fn Node* parse_while(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_WHILE);
    consume(parser, context, lexer, TokenType.LPAREN);

    Node* expr = parse_expr(parser, context, lexer);

    consume(parser, context, lexer, TokenType.RPAREN);

    NodeList statements = parse_compound(parser, context, lexer);
    Range    end        = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.WHILE, start, end; node) {
        node.while_node.expr       = expr;
        node.while_node.statements = statements;
    };
}

fn FunctionSignature parse_function_signature(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node*    type       = parse_type(parser, context, lexer);
    Node*    name       = parse_identifier(parser, context, lexer);
    NodeList parameters = parse_parameters(parser, context, lexer);

    return { type, name, parameters };
}

fn Node* parse_base(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;

    consume(parser, context, lexer, TokenType.KW_BASE);

    Node* name = parse_identifier(parser, context, lexer);

    consume(parser, context, lexer, TokenType.LBRACE);

    NodeList functions;
    functions.init(context.alloc);

    while (parser.current.type != TokenType.RBRACE) {
        Range function_start = parser.current.range.start;

        FunctionSignature sig = parse_function_signature(parser, context, lexer);

        consume(parser, context, lexer, TokenType.SEMI);

        Range function_end = peek(parser, lexer, -1).range.end;

        functions.push(@make_node(context, NodeType.FUNCTION, function_start, function_end; node) {
            node.function_node.type       = sig.type;
            node.function_node.name       = sig.name;
            node.function_node.parameters = sig.parameters;
        });
    }

    consume(parser, context, lexer, TokenType.RBRACE);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.BASE, start, end; node) {
        node.base_node.name      = name;
        node.base_node.functions = functions;
    };
}

fn Node* parse_real(Parser* parser, CompileContext* context, Lexer* lexer) {
    Range start = parser.current.range.start;
    Range end   = parser.current.range.end;

    String real = parser.current.value;

    consume(parser, context, lexer, TokenType.REAL);

    return @make_node(context, NodeType.REAL, start, end; node) {
        node.real_node.real = real;
    };
}

fn void consume(Parser* parser, CompileContext* context, Lexer* lexer, TokenType type) {
    if (parser.current.type != type) {
        highlighter::error(context, context.current_file, parser.current.range.start, parser.current.range.end, "Expected type '%s', got '%s'", type, parser.current.type);
    }

    if ((long)parser.cursor + 1 < lexer.context.tokens.len()) {
        parser.current = lexer.context.tokens.get(++parser.cursor);
    }
}

fn Token peek(Parser* parser, Lexer* lexer, int count = 1) {
    if ((long)parser.cursor + count >= lexer.context.tokens.len()) {
        return types::TOKEN_EMPTY;
    }

    return lexer.context.tokens[(long)parser.cursor + count];
}

fn Mark save(Parser* parser) {
    return { parser.cursor, parser.current };
}

fn void restore(Parser* parser, Mark mark) {
    parser.cursor  = mark.cursor;
    parser.current = mark.current;
}

fn Node* clone_node(CompileContext* context, Node* node) {
    Node* clone = alloc::new(context.alloc, Node);
    *clone = *node;
    return clone;
}

fn bool starts_type(TokenType type) {
    return type == TokenType.ASTERISK
        || type == TokenType.LBRACKET
        || type == TokenType.IDENT;
}

fn bool is_qualified_type_ident(Parser* parser, CompileContext* context, Lexer* lexer) {
    Mark mark = save(parser);

    consume(parser, context, lexer, TokenType.IDENT);

    while (parser.current.type == TokenType.PERIOD) {
        consume(parser, context, lexer, TokenType.PERIOD);

        if (parser.current.type != TokenType.IDENT) {
            restore(parser, mark);
            return false;
        }

        consume(parser, context, lexer, TokenType.IDENT);
    }

    bool result = parser.current.type == TokenType.IDENT
        || parser.current.type == TokenType.ASTERISK
        || parser.current.type == TokenType.LBRACKET;

    restore(parser, mark);
    return result;
}

macro Node* @make_node(CompileContext* context, NodeType type, Range from, Range to; @body(Node*)) {
    Node* node = alloc::new(context.alloc, Node);

    node.type       = type;
    node.range.from = from;
    node.range.to   = to;

    @body(node);

    return node;
}

fn void free(Parser* parser, Allocator alloc) {
    core::node_free(parser.context.ast, alloc);
}
