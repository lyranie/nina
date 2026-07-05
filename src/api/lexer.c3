module nina::api::lexer;

import nina::lexer;
import nina::types;

fn Lexer* lexer_create(CompileContext* context, CChar* path) @export("nina_lexer_create") {
    return lexer::create(context, ((ZString)path).str_view().copy(context.alloc));
}

fn void lexer_tokenize(CompileContext* context, Lexer* lexer) @export("nina_lexer_tokenize") {
    lexer::tokenize(lexer, context);
}

fn void lexer_free(CompileContext* context, Lexer* lexer) @export("nina_lexer_free") {
    lexer::free(lexer, context.alloc);
}
