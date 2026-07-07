module nina::api::generator;

import nina::types;
import nina::generator;

fn Generator* generator_create(CompileContext* context) @export("nina_generator_create") {
    return generator::create(context);
}

fn void generator_generate(CompileContext* context, Generator* generator) @export("nina_generator_generate") {
    generator::generate(generator, context);
}

fn void generator_free(CompileContext* context, Generator* generator) @export("nina_generator_free") {
    generator::free(generator, context.alloc);
}
