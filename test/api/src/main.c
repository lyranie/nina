#include <stdio.h>
#include "nina.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        printf("Usage: %s <file>\n", argv[0]);
		return 0;
	}

	// TODO: update to parse multiple files

    Nina_Context *context = nina_context_create();

    nina_profiler_commit(context, "Lexer");

    Nina_Lexer *lexer = nina_lexer_create(context, argv[1]);
	nina_lexer_tokenize(context, lexer);

    nina_profiler_commit(context, "Parser");

    Nina_Parser *parser = nina_parser_create(context, lexer);
    nina_parser_parse(context, parser, lexer);

    nina_profiler_commit(context, "Analyser");

    Nina_Analyser *analyser = nina_analyser_create(context, argv[1]);
	nina_analyser_analyse(context, analyser, parser);

    nina_profiler_commit(context, "Generator");

	Nina_Generator *generator = nina_generator_create(context, parser);
	nina_generator_generate(context, generator, parser);

    nina_profiler_commit(context, "Cleanup");

    nina_lexer_free(context, lexer);
	nina_parser_free(context, parser);
	nina_analyser_free(context, analyser);
	nina_generator_free(context, generator);

	nina_profiler_end(context);

    nina_context_free(context);

    return 0;
}
