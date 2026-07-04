module nina::parser;

import nina::core;
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
}

fn void parse_mod(Parser* parser, CompileContext* context, Lexer* lexer) {
    consume(parser, context, lexer, TokenType.KW_MOD);

    Node* path = parse_path(parser, context, lexer);
    consume(parser, context, lexer, TokenType.SEMI);

    List{Node*} statements;
    statements.init(context.alloc);

    while (parser.current.type != TokenType.EOF) {
        switch (parser.current.type) {
        case TokenType.IDENT:
            statements.push(parse_function(parser, context, lexer));
        case TokenType.KW_EXT:
            statements.push(parse_ext(parser, context, lexer));
        default:
            highlighter::error(context, parser.current.range.start, parser.current.range.end, "Statement expected, got '%s'", parser.current.type);
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

    Node*    type       = parse_type(parser, context, lexer);
    Node*    name       = parse_identifier(parser, context, lexer);
    NodeList parameters = parse_parameters(parser, context, lexer);
    NodeList statements = parse_compound(parser, context, lexer);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.FUNCTION, start, end; node) {
        node.function_node.type       = type;
        node.function_node.name       = name;
        node.function_node.parameters = parameters;
        node.function_node.statements = statements;
    };
}

fn Node* parse_type(Parser* parser, CompileContext* context, Lexer* lexer) => @pool() {
    Range start = parser.current.range.start;
    Node* name  = parse_identifier(parser, context, lexer);

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
        Range parameter_start = parser.current.range.start;
        Node* parameter_type  = null;

        if (
            peek(parser, lexer).type == TokenType.ASTERISK ||
            peek(parser, lexer).type == TokenType.LBRACKET ||
            peek(parser, lexer).type == TokenType.IDENT)
        {
            parameter_type = parse_type(parser, context, lexer);
        }

        Node* parameter_name = parse_identifier(parser, context, lexer);
        bool  parameter_vaarg;

        if (parser.current.type == TokenType.ELLIPSE) {
            parameter_vaarg = true;
            consume(parser, context, lexer, TokenType.ELLIPSE);
        }

        Range parameter_end = peek(parser, lexer, -1).range.end;

        parameters.push(@make_node(context, NodeType.PARAMETER, parameter_start, parameter_end; node) {
            node.parameter_node.type  = parameter_type;
            node.parameter_node.name  = parameter_name;
            node.parameter_node.vaarg = parameter_vaarg;
        });

        while (parser.current.type == TokenType.COMMA) {
            consume(parser, context, lexer, TokenType.COMMA);

            Range other_parameter_start = parser.current.range.start;
            Node* other_parameter_type  = null;
            
            if (
                peek(parser, lexer).type == TokenType.ASTERISK ||
                peek(parser, lexer).type == TokenType.LBRACKET ||
                peek(parser, lexer).type == TokenType.IDENT)
            {
                other_parameter_type = parse_type(parser, context, lexer);
            }

            Node* other_parameter_name = parse_identifier(parser, context, lexer);
            bool  other_parameter_vaarg;

            if (parser.current.type == TokenType.ELLIPSE) {
                other_parameter_vaarg = true;
                consume(parser, context, lexer, TokenType.ELLIPSE);
            }
            
            Range other_parameter_end = peek(parser, lexer, -1).range.end;

            parameters.push(@make_node(context, NodeType.PARAMETER, other_parameter_start, other_parameter_end; node) {
                node.parameter_node.type  = other_parameter_type;
                node.parameter_node.name  = other_parameter_name;
                node.parameter_node.vaarg = other_parameter_vaarg;
            });
        }
    }

    consume(parser, context, lexer, TokenType.RPAREN);

    return parameters;
}

fn NodeList parse_compound(Parser* parser, CompileContext* context, Lexer* lexer) {
    NodeList statements;
    statements.init(context.alloc);

    consume(parser, context, lexer, TokenType.LBRACE);
    
    while (parser.current.type != TokenType.RBRACE) {
        switch (parser.current.type) {
        case TokenType.KW_RET:
            statements.push(parse_ret(parser, context, lexer));
        case TokenType.IDENT:
            statements.push(parse_identifier_statement(parser, context, lexer));
        default:
            highlighter::error(context, parser.current.range.start, parser.current.range.end, "Statement expected, got '%s'", parser.current.type);
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
    Node* node = parse_term(parser, context, lexer);

    while (parser.current.type == TokenType.PLUS  ||
           parser.current.type == TokenType.MINUS ||
           parser.current.type == TokenType.AND   ||
           parser.current.type == TokenType.OR) {
        Token operator = parser.current;

        consume(parser, context, lexer, operator.type);

        Node* left = alloc::new(context.alloc, Node);
        *left = *node;

        Node* right = parse_term(parser, context, lexer);
        
        node = @make_node(context, NodeType.BIN, left.range.from, right.range.to; unused) {
            node.bin_node.operator = operator;
            node.bin_node.left     = left;
            node.bin_node.right    = right;
        };
    }

    return node;
}

fn Node* parse_term(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = parse_factor(parser, context, lexer);

    while (parser.current.type == TokenType.ASTERISK ||
           parser.current.type == TokenType.SLASH    ||
           parser.current.type == TokenType.IS_EQUAL ||
           parser.current.type == TokenType.NOT_EQUAL) {
        Token operator = parser.current;

        consume(parser, context, lexer, operator.type);

        Node* left = alloc::new(context.alloc, Node);
        *left = *node;

        Node* right = parse_factor(parser, context, lexer);
        
        node = @make_node(context, NodeType.BIN, left.range.from, right.range.to; unused) {
            node.bin_node.operator = operator;
            node.bin_node.left     = left;
            node.bin_node.right    = right;
        };
    }

    return node;
}

fn Node* parse_factor(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = null;

    switch (parser.current.type) {
    case TokenType.INT:
        node = parse_int(parser, context, lexer);
    case TokenType.TRUE:
    case TokenType.FALSE:
        node = parse_bool(parser, context, lexer);
    case TokenType.STRING:
        node = parse_string(parser, context, lexer);
    default:
        highlighter::error(context, parser.current.range.start, parser.current.range.end, "Expression expected, got '%s'", parser.current.type);
    }

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

    Node*    type       = parse_type(parser, context, lexer);
    Node*    name       = parse_identifier(parser, context, lexer);
    NodeList parameters = parse_parameters(parser, context, lexer);

    consume(parser, context, lexer, TokenType.SEMI);

    Range end = peek(parser, lexer, -1).range.end;

    return @make_node(context, NodeType.EXT, start, end; node) {
        node.ext_node.type       = type;
        node.ext_node.name       = name;
        node.ext_node.parameters = parameters;
    };
}

fn Node* parse_identifier_statement(Parser* parser, CompileContext* context, Lexer* lexer) {
    switch (peek(parser, lexer).type) {
    case TokenType.LPAREN:
        Node* node = parse_call(parser, context, lexer);

        consume(parser, context, lexer, TokenType.SEMI);

        return node;
    default:
        highlighter::panic();
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

fn void consume(Parser* parser, CompileContext* context, Lexer* lexer, TokenType type) {
    if (parser.current.type != type) {
        highlighter::error(context, parser.current.range.start, parser.current.range.end, "Expected type '%s', got '%s'", type, parser.current.type);
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
