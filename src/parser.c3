module nina::parser;

import nina::core;
import nina::types;

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
    consume(parser, lexer, TokenType.KW_MOD);

    Node* path = parse_path(parser, context, lexer);
    consume(parser, lexer, TokenType.SEMI);

    List{Node*} statements;
    statements.init(context.alloc);

    while (parser.current.type != TokenType.EOF) {
        switch (parser.current.type) {
        case TokenType.IDENT:
            statements.push(parse_function(parser, context, lexer));
        default:
            io::eprintfn("missing parser case for type '%s'", parser.current.type);
            os::exit(1);
        }
    }

    consume(parser, lexer, TokenType.EOF);

    parser.context.ast.type                = NodeType.MOD;
    parser.context.ast.mod_node.path       = path;
    parser.context.ast.mod_node.statements = statements;

    statements.free();
}

fn Node* parse_path(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = alloc::new(context.alloc, Node);
    Range start     = parser.current.range.start;

    DString path;
    path.init(context.alloc);

    path.append(parser.current.value);
    consume(parser, lexer, TokenType.IDENT);

    while (parser.current.type == TokenType.PERIOD) {
        path.append(".");
        consume(parser, lexer, TokenType.PERIOD);

        path.append(parser.current.value);
        consume(parser, lexer, TokenType.IDENT);
    }

    Range end = parser.current.range.end;

    node.type = NodeType.PATH;
    node.path_node.path = path.copy_str(context.alloc);

    path.free();

    return node;
}

fn Node* parse_function(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node  = alloc::new(context.alloc, Node);
    Range start = parser.current.range.start;

    Node*    type       = parse_type(parser, context, lexer);
    Node*    name       = parse_identifier(parser, context, lexer);
    NodeList parameters = parse_parameters(parser, context, lexer);
    NodeList statements = parse_compound(parser, context, lexer);

    node.type = NodeType.FUNCTION;
    node.function_node.type       = type;
    node.function_node.name       = name;
    node.function_node.parameters = parameters;
    node.function_node.statements = statements;

    return node;
}

fn Node* parse_type(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = alloc::new(context.alloc, Node);

    Node* name = parse_identifier(parser, context, lexer);

    DString suffix;
    suffix.tinit();

    while (parser.current.type == TokenType.ASTERISK || parser.current.type == TokenType.LBRACKET)
    {
        switch (parser.current.type)
        {
        case TokenType.ASTERISK:
            suffix.append('*');
            consume(parser, lexer, TokenType.ASTERISK);
        case TokenType.LBRACKET:
            suffix.append("[]");
            consume(parser, lexer, TokenType.LBRACKET);
            consume(parser, lexer, TokenType.RBRACKET);
        default:
            io::eprintn("penis");
            os::exit(1);
        }
    }

    node.type             = NodeType.TYPE;
    node.type_node.name   = name;
    node.type_node.suffix = suffix.copy_str(context.alloc);

    suffix.free();

    return node;
}

fn Node* parse_identifier(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = alloc::new(context.alloc, Node);

    String name = parser.current.value;

    consume(parser, lexer, TokenType.IDENT);
    
    node.type            = IDENT;
    node.ident_node.name = name;

    return node;
}

fn NodeList parse_parameters(Parser* parser, CompileContext* context, Lexer* lexer) {
    NodeList parameters;
    parameters.init(context.alloc);

    consume(parser, lexer, TokenType.LPAREN);
    
    if (parser.current.type != TokenType.RPAREN) {
        Node* parameter_node = alloc::new(context.alloc, Node);

        Node* parameter_type = parse_type(parser, context, lexer);
        Node* parameter_name = parse_identifier(parser, context, lexer);

        parameter_node.type = PARAMETER;
        parameter_node.parameter_node.type = parameter_type;
        parameter_node.parameter_node.name = parameter_name;

        parameters.push(parameter_node);

        while (parser.current.type == TokenType.COMMA) {
            consume(parser, lexer, TokenType.COMMA);

            Node* other_parameter_node = alloc::new(context.alloc, Node);

            Node* other_parameter_type = parse_type(parser, context, lexer);
            Node* other_parameter_name = parse_identifier(parser, context, lexer);

            other_parameter_node.type = PARAMETER;
            other_parameter_node.parameter_node.type = other_parameter_type;
            other_parameter_node.parameter_node.name = other_parameter_name;

            parameters.push(other_parameter_node);
        }
    }

    consume(parser, lexer, TokenType.RPAREN);

    return parameters;
}

fn NodeList parse_compound(Parser* parser, CompileContext* context, Lexer* lexer) {
    NodeList statements;
    statements.init(context.alloc);

    consume(parser, lexer, TokenType.LBRACE);
    
    while (parser.current.type != TokenType.RBRACE) {
        switch (parser.current.type) {
        case TokenType.KW_RET:
            statements.push(parse_ret(parser, context, lexer));
        default:
            io::eprintfn("missing parser compound function for type '%s'", parser.current.type);
        }
    }

    consume(parser, lexer, TokenType.RBRACE);

    return statements;
}

fn Node* parse_ret(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = alloc::new(context.alloc, Node);

    consume(parser, lexer, TokenType.KW_RET);

    Node* value = null;
    if (parser.current.type != TokenType.SEMI) {
        value = parse_expr(parser, context, lexer);
    }

    consume(parser, lexer, TokenType.SEMI);

    node.type           = NodeType.RET;
    node.ret_node.value = value;

    return node;
}

fn Node* parse_expr(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = parse_term(parser, context, lexer);

    while (parser.current.type == TokenType.PLUS  ||
           parser.current.type == TokenType.MINUS ||
           parser.current.type == TokenType.AND   ||
           parser.current.type == TokenType.OR) {
        Token operator = parser.current;

        consume(parser, lexer, operator.type);

        Node* left = alloc::new(context.alloc, Node);
        *left = *node;

        Node* right = parse_term(parser, context, lexer);
        
        node.type = NodeType.BIN;
        node.bin_node.operator = operator;
        node.bin_node.left     = left;
        node.bin_node.right    = right;
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

        consume(parser, lexer, operator.type);

        Node* left = alloc::new(context.alloc, Node);
        *left = *node;

        Node* right = parse_factor(parser, context, lexer);
        
        node.type = NodeType.BIN;
        node.bin_node.operator = operator;
        node.bin_node.left     = left;
        node.bin_node.right    = right;
    }

    return node;
}

fn Node* parse_factor(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = null;

    switch (parser.current.type) {
    case INT:
        node = parse_int(parser, context, lexer);
    default:
        io::eprintfn("expression expected, got '%s'", parser.current.type);
        // highlight::error(self.allocator, self.file, self.current.from, self.current.to, "Expected expression, got '%s'", self.current.type);
        os::exit(1);
    }

    return node;
}

fn Node* parse_int(Parser* parser, CompileContext* context, Lexer* lexer) {
    Node* node = alloc::new(context.alloc, Node);

    String number = parser.current.value;

    consume(parser, lexer, TokenType.INT);

    node.type            = INT;
    node.int_node.number = number;

    return node;
}

fn void consume(Parser* parser, Lexer* lexer, TokenType type) {
    if (parser.current.type != type) {
        io::eprintfn(
            "Expected type '%s', got '%s' '%s(%d:%d)'",
            type,
            parser.current.type,
            lexer.filepath,
            parser.current.range.start.line,
            parser.current.range.start.column
        );
        os::exit(1);
    }

    if ((long)parser.cursor + 1 < lexer.context.tokens.len()) {
        parser.current = lexer.context.tokens.get(++parser.cursor);
    }
}

fn void free(Parser* parser, Allocator alloc) {
    core::node_free(parser.context.ast, alloc);
}
