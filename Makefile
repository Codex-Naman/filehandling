CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wpedantic
LDFLAGS ?=

.PHONY: all clean test

all: mycp

mycp: mycp.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: mycp
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	printf 'hello low-level backup\n' > "$$tmp/source"; chmod 640 "$$tmp/source"; \
	./mycp --preserve --verify --benchmark "$$tmp/source" "$$tmp/dest"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/dest")"; \
	test "$$(stat -c %a "$$tmp/source")" = "$$(stat -c %a "$$tmp/dest")"; \
	mkdir "$$tmp/tree"; printf 'nested\n' > "$$tmp/tree/a"; ./mycp -r --verify "$$tmp/tree" "$$tmp/out"; \
	test -f "$$tmp/out/a"; test "$$(cat "$$tmp/out/a")" = nested; \
	printf 'hello l' > "$$tmp/partial"; ./mycp --resume "$$tmp/source" "$$tmp/partial"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/partial")"; \
	printf 'wrong' > "$$tmp/mismatch"; ./mycp --resume "$$tmp/source" "$$tmp/mismatch"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/mismatch")"; echo 'tests: ok'


clean:
	rm -f mycp
