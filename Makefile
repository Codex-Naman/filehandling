CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wpedantic
LDFLAGS ?=

.PHONY: all clean test verify help copy copy-paste recursive backup sync all-features

SOURCE ?=
DEST ?=
LOG ?= mycp.log
BUFFER ?= 1M

COMMON_FLAGS = -r --buffer $(BUFFER) --preserve --progress --verify

all: mycp

mycp: mycp.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: mycp
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	printf 'hello low-level backup\n' > "$$tmp/source"; chmod 640 "$$tmp/source"; \
	./mycp --preserve --verify --benchmark "$$tmp/source" "$$tmp/dest"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/dest")"; \
	test "$$(stat -c %a "$$tmp/source")" = "$$(stat -c %a "$$tmp/dest")"; \
	mkdir -p "$$tmp/tree/nested/deeper"; printf 'nested\n' > "$$tmp/tree/a"; printf 'deep\n' > "$$tmp/tree/nested/deeper/file"; ./mycp -r --verify "$$tmp/tree" "$$tmp/out"; \
	test -f "$$tmp/out/a"; test "$$(cat "$$tmp/out/a")" = nested; \
	test -f "$$tmp/out/nested/deeper/file"; test "$$(cat "$$tmp/out/nested/deeper/file")" = deep; \
	printf 'hello l' > "$$tmp/partial"; ./mycp --resume "$$tmp/source" "$$tmp/partial"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/partial")"; \
	printf 'wrong' > "$$tmp/mismatch"; ./mycp --resume "$$tmp/source" "$$tmp/mismatch"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/mismatch")"; echo 'tests: ok'

verify: test

help:
	@echo 'Usage:'
	@echo '  make copy SOURCE=source DEST=destination'
	@echo '  make copy-paste SOURCE=source DEST=destination'
	@echo '  make recursive SOURCE=directory DEST=directory'
	@echo '  make backup SOURCE=source DEST=destination'
	@echo '  make sync SOURCE=directory DEST=directory'
	@echo '  make all-features SOURCE=source DEST=destination LOG=mycp.log'
	@echo '  add BUFFER=64K, 1M, or 4M to choose the buffer size'
	@echo ''
	@echo 'Targets:'
	@echo '  copy          copy files or directories with progress and verification'
	@echo '  recursive     recursively copy a directory with verification'
	@echo '  backup        copy with resume support'
	@echo '  sync          recursive incremental synchronization'
	@echo '  all-features  enable every available command-line feature'
	@echo '  verify        run the automated verification tests'

copy: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	./mycp $(COMMON_FLAGS) "$(SOURCE)" "$(DEST)"

copy-paste: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	@set -eu; \
	buffer="$(BUFFER)"; \
	if [ "$(origin BUFFER)" = "file" ]; then \
		echo 'Choose a buffer size for this copy:'; \
		echo '  64K  128K  256K  512K  1M  4M  16M  64M'; \
		printf 'Buffer size [1M]: '; \
		read -r selected; \
		if [ -n "$$selected" ]; then buffer="$$selected"; fi; \
	fi; \
	./mycp -r --preserve --progress --verify --buffer "$$buffer" \
		"$(SOURCE)" "$(DEST)"

recursive: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE directory is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST directory is required'; exit 2)
	./mycp -r --buffer "$(BUFFER)" --preserve --progress --verify \
		"$(SOURCE)" "$(DEST)"

backup: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	./mycp $(COMMON_FLAGS) --resume "$(SOURCE)" "$(DEST)"

sync: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	./mycp -r $(COMMON_FLAGS) --resume --sync --benchmark \
		--log "$(LOG)" "$(SOURCE)" "$(DEST)"

all-features: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	./mycp -r --buffer "$(BUFFER)" --preserve --progress --verify --resume --info \
		--benchmark --sync --verbose --log "$(LOG)" \
		"$(SOURCE)" "$(DEST)"


clean:
	rm -f mycp
