#ifndef NINA_H
#define NINA_H

#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Nina_Context   Nina_Context;
typedef struct Nina_Lexer     Nina_Lexer;
typedef struct Nina_Parser    Nina_Parser;
typedef struct Nina_Analyser  Nina_Analyser;
typedef struct Nina_Generator Nina_Generator;

Nina_Context *nina_context_create(void);
void nina_context_free(Nina_Context *context);

// -- LEXER --
Nina_Lexer *nina_lexer_create(Nina_Context *context, const char *path);
void nina_lexer_tokenize(Nina_Context *context, Nina_Lexer *lexer);
void nina_lexer_free(Nina_Context *context, Nina_Lexer *lexer);

// -- PARSER --
Nina_Parser *nina_parser_create(Nina_Context *context, Nina_Lexer *lexer);
void nina_parser_parse(Nina_Context *context, Nina_Parser *parser, Nina_Lexer *lexer);
void nina_parser_free(Nina_Context *context, Nina_Parser *parser);

// -- ANALYSER --
Nina_Analyser *nina_analyser_create(Nina_Context *context, const char *path);
void nina_analyser_analyse(Nina_Context *context, Nina_Analyser *analyser, Nina_Parser *parser);
void nina_analyser_free(Nina_Context *context, Nina_Analyser *analyser);

// -- GENERATOR --
Nina_Generator *nina_generator_create(Nina_Context *context, Nina_Parser *parser);
void nina_generator_generate(Nina_Context *context, Nina_Generator *generator, Nina_Parser *parser);
void nina_generator_free(Nina_Context *context, Nina_Generator *generator);

// -- PROFILER --
void nina_profiler_commit(Nina_Context *context, const char *name);
void nina_profiler_end(Nina_Context *context);

#ifdef __cplusplus
}
#endif

#endif // NINA_H
