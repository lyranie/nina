.PHONY: all compiler lib copy-lib test-api test-unit clean

all: compiler copy-std lib copy-lib

debug: compile-debug copy-std lib copy-lib

compile-debug:
	c3c build nina -D DEBUG

compiler:
	c3c build nina

copy-std:
	cp stdlib -r build/

lib:
	c3c build libnina

copy-lib: lib
	mkdir -p test/api/lib
	cp build/libnina.so test/api/lib/

test-api: copy-lib
	$(MAKE) -C test/api
	./test/api/build/nina-api-test test/src/main.nina

create-runner: lib
	c3c compile -o test/unit/runner/runner --libdir lib --lib llvm -l build/libnina.so test/unit/runner/runner.c3 src/types.c3

test-unit: create-runner
	test/unit/runner/runner

clean:
	rm -rf build
