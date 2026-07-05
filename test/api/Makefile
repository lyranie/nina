CC        := cc
CFLAGS    := -Iinclude -Wall -Wextra -std=c11
LDFLAGS   := -Llib -lnina
RPATH     := -Wl,-rpath,'$$ORIGIN/../lib'
TARGET    := build/nina-api-test

.PHONY: all clean

all: $(TARGET)

$(TARGET): src/main.c include/nina.h | build
	$(CC) $(CFLAGS) src/main.c -o $(TARGET) $(LDFLAGS) $(RPATH)

build:
	mkdir -p build

clean:
	rm -rf build
