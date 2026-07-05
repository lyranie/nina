module nina::api::parser;

import nina::parser;
import nina::types;

fn Parser* parser_create(CompileContext* context, Lexer* lexer) @export("nina_parser_create") {
    return parser::create(context.alloc, lexer);
}

fn void parser_parse(CompileContext* context, Parser* parser, Lexer* lexer) @export("nina_parser_parse") {
    parser::parse(parser, context, lexer);
}

fn void parser_free(CompileContext* context, Parser* parser) @export("nina_parser_free") {
    parser::free(parser, context.alloc);
}
