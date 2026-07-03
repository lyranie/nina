module nina::lexer;

import nina::core;
import nina::types;
import nina::highlighter;

import std::io;
import std::os;

fn Lexer* create(Allocator alloc, String file) {
    Lexer* lexer = alloc::new(alloc, Lexer);

    char[]? content = file::load(alloc, file);
    if (catch err = content) {
        io::eprintfn("Failed to create lexer: %s", err);
        alloc::free(alloc, lexer);

        return null;
    }

    char current;

    if (content.len != 0) {
        current = content[0];
    } else {
        current = 0;
    }

    lexer.filepath = file;
    lexer.content  = (String)content;
    lexer.current  = current;
    lexer.cursor   = 0;
    lexer.range    = { .line = 1, .column = 0 };
    
    lexer.context.tokens.init(alloc);

    return lexer;
}

fn void tokenize(Lexer* lexer, CompileContext* context) {
    while (lexer.current != 0) {
        while (lexer.current.is_space()) {
            lexer.range.column++;

            if (lexer.current.is_newline()) {
                lexer.range.column = 0;
                lexer.range.line++;
            }

            consume(lexer);
        }

        if (lexer.current == 0) {
            break;
        }

        Range start_range = lexer.range;

        if (lexer.current == '/' && peek(lexer) == '/') {
            line_comment(lexer);
        } else if (lexer.current == '/' && peek(lexer) == '*') {
            block_comment(lexer);
        } else if (lexer.current.is_alpha() || lexer.current == '_') {
            word(lexer, context);
        } else if (lexer.current.is_digit()) {
            number(lexer, context);
        } else if (false) {
            // strings
        } else if (lexer.current == '.' && peek(lexer) == '.' && peek(lexer, 2) == '.') {
            make_token(lexer, TokenType.ELLIPSE, "...");
        } else if (lexer.current == '|' && peek(lexer) == '|') {
            make_token(lexer, TokenType.OR, "||");
        } else if (lexer.current == '&' && peek(lexer) == '&') {
            make_token(lexer, TokenType.AND, "&&");
        } else if (lexer.current == '=' && peek(lexer) == '=') {
            make_token(lexer, TokenType.IS_EQUAL, "==");
        } else if (lexer.current == '!' && peek(lexer) == '=') {
            make_token(lexer, TokenType.NOT_EQUAL, "!=");
        } else if (lexer.current == '>' && peek(lexer) == '=') {
            make_token(lexer, TokenType.GTE, ">=");
        } else if (lexer.current == '<' && peek(lexer) == '=') {
            make_token(lexer, TokenType.LTE, "<=");
        } else if (lexer.current == ';') {
            make_token(lexer, TokenType.SEMI, ";");
        } else if (lexer.current == '(') {
            make_token(lexer, TokenType.LPAREN, "(");
        } else if (lexer.current == ')') {
            make_token(lexer, TokenType.RPAREN, ")");
        } else if (lexer.current == '[') {
            make_token(lexer, TokenType.LBRACKET, "[");
        } else if (lexer.current == ']') {
            make_token(lexer, TokenType.RBRACKET, "]");
        } else if (lexer.current == '{') {
            make_token(lexer, TokenType.LBRACE, "{");
        } else if (lexer.current == '}') {
            make_token(lexer, TokenType.RBRACE, "}");
        } else if (lexer.current == '<') {
            make_token(lexer, TokenType.LANGLE, "<");
        } else if (lexer.current == '>') {
            make_token(lexer, TokenType.RANGLE, ">");
        } else if (lexer.current == '+') {
            make_token(lexer, TokenType.PLUS, "+");
        } else if (lexer.current == '-') {
            make_token(lexer, TokenType.MINUS, "-");
        } else if (lexer.current == '*') {
            make_token(lexer, TokenType.ASTERISK, "*");
        } else if (lexer.current == '/') {
            make_token(lexer, TokenType.SLASH, "/");
        } else if (lexer.current == '=') {
            make_token(lexer, TokenType.EQUALS, "=");
        } else if (lexer.current == '.') {
            make_token(lexer, TokenType.PERIOD, ".");
        } else if (lexer.current == ',') {
            make_token(lexer, TokenType.COMMA, ",");
        } else if (lexer.current == '&') {
            make_token(lexer, TokenType.AMP, "&");
        }

        if (!core::range_compare(lexer.range, start_range)) {
            Range end = { start_range.line, start_range.column + 1 };

            highlighter::error(context, start_range, end, "Unrecognized character '%c'", lexer.current);
        }
    }

    lexer.context.tokens.push({
        .type  = TokenType.EOF,
        .value = "<eof>",
        .range = {
            .start = lexer.range,
            .end   = {
                .line   = lexer.range.line,
                .column = lexer.range.column + 1
            }
        }
    });
}

fn void line_comment(Lexer* lexer) {
    consume(lexer, 2);

    while (!lexer.current.is_newline()) {
        consume(lexer);
    }

    consume(lexer);

    lexer.range.column = 0;
    lexer.range.line++;
}

fn void block_comment(Lexer* lexer) {
    consume(lexer, 2);

    while (lexer.current != 0 && !(lexer.current == '*' && peek(lexer) == '/')) {
        lexer.range.column++;

        if (lexer.current.is_newline()) {
            lexer.range.column = 0;
            lexer.range.line++;
        }

        consume(lexer);
    }

    if (lexer.current != 0) {
        consume(lexer, 2, true);
    }
}

fn void word(Lexer* lexer, CompileContext* context) => @pool() {
    DString word;
    word.tinit();

    Range start = lexer.range;

    while (lexer.current.is_alnum() || lexer.current == '_') {
        word.append(lexer.current);
        consume(lexer, column: true);
    }

    TokenType type;
    switch (word.str_view()) {
    case "mod":
        type = TokenType.KW_MOD;
    case "ret":
        type = TokenType.KW_RET;
    case "ext":
        type = TokenType.KW_EXT;
    default:
        type = TokenType.IDENT;
    }

    lexer.context.tokens.push({
        .type  = type,
        .value = word.copy_str(context.alloc),
        .range = {
            .start = start,
            .end   = lexer.range
        }
    });

    word.free();
}

fn void number(Lexer* lexer, CompileContext* context) => @pool() {
    DString number;
    number.tinit();

    Range     start = lexer.range;
    TokenType type  = TokenType.INT;

    while (lexer.current.is_digit() || lexer.current == '_') {
        number.append(lexer.current);
        consume(lexer, column: true);
    }

    if (lexer.current == '.') {
        number.append(".");
        consume(lexer, column: true);

        // TODO: error if no number after e.g. `12.`

        while (lexer.current.is_digit() || lexer.current == '_') {
            number.append(lexer.current);
            consume(lexer, column: true);
        }

        type = TokenType.REAL;
    }

    lexer.context.tokens.push({
        .type  = type,
        .value = number.copy_str(context.alloc),
        .range = {
            .start = start,
            .end   = lexer.range
        }
    });
}

fn void consume(Lexer* lexer, int count = 1, bool column = false) {
    lexer.cursor += count;

    if (column) {
        lexer.range.column += count;
    }

    if (lexer.cursor < lexer.content.len) {
        lexer.current = lexer.content[lexer.cursor];
    } else {
        lexer.current = 0;
    }
}

fn char peek(Lexer* lexer, int count = 1) {
    if ((long)lexer.cursor + count >= lexer.content.len) {
        return 0;
    } else {
        return lexer.content[lexer.cursor + count];
    }
}

fn void make_token(Lexer* lexer, TokenType type, String value, void* data = null) {
    Range start = lexer.range;
    Range end   = {
        .line   = start.line,
        .column = start.column + value.len
    };

    lexer.context.tokens.push({
        .type  = type,
        .value = value,
        .range = {
            .start = start,
            .end   = end
        },
        .data  = data
    });

    consume(lexer, value.len, true);
}

fn void free(Lexer* lexer, Allocator alloc) {
    alloc::free(alloc, lexer.filepath);
    alloc::free(alloc, lexer.content);
}
