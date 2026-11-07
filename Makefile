CC ?= cc
CXX ?= c++
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wpedantic
LDFLAGS ?=

GTEST_CFLAGS := $(shell pkg-config --cflags gtest_main 2>/dev/null)
GTEST_LIBS := $(shell pkg-config --libs gtest_main 2>/dev/null)

.PHONY: all clean test verify verify-recursive integration gtest valgrind coverage misra test-all display help copy copy-paste recursive preserve backup log sync all-features

SOURCE ?=
DEST ?=
LOG ?= mycp.log
BUFFER ?= 1024

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

integration: mycp
	MYCP=./mycp sh tests/integration.sh

gtest: mycp
	@command -v pkg-config >/dev/null 2>&1 || (echo 'pkg-config is required for gtest'; exit 2)
	@test -n "$(GTEST_LIBS)" || (echo 'GoogleTest development files are required'; exit 2)
	@mkdir -p .test-build
	$(CXX) -std=c++17 -Wall -Wextra -Wpedantic $(GTEST_CFLAGS) \
		tests/mycp_gtest.cpp $(GTEST_LIBS) -o .test-build/mycp_gtest
	./.test-build/mycp_gtest

valgrind: mycp
	@command -v valgrind >/dev/null 2>&1 || (echo 'Valgrind is required'; exit 2)
	MYCP=./mycp sh tests/valgrind.sh

coverage:
	@rm -rf coverage
	@mkdir -p coverage
	$(CC) -O0 -g -std=c11 -Wall -Wextra -Wpedantic --coverage \
		-o coverage/mycp mycp.c
	MYCP=./coverage/mycp sh tests/integration.sh
	gcov -b -c -o coverage mycp.c
	@mv -f mycp.c.gcov coverage/mycp.c.gcov
	@echo 'coverage: generated mycp.c.gcov'

misra:
	@command -v cppcheck >/dev/null 2>&1 || (echo 'Cppcheck is required'; exit 2)
	cppcheck --enable=all --inconclusive --error-exitcode=1 --std=c11 --addon=misra \
		--suppress=missingIncludeSystem mycp.c

test-all: integration gtest valgrind coverage misra

verify-recursive: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE directory is required'; exit 2)
	@test -d "$(SOURCE)" || (echo "SOURCE is not a directory: $(SOURCE)"; exit 2)
	@set -eu; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	mkdir -p "$$tmp/destination"; \
	./mycp -r --buffer "$(BUFFER)" --preserve --progress --verify \
		"$(SOURCE)" "$$tmp/destination"; \
	name=$$(basename -- "$(SOURCE)"); \
	diff -r "$(SOURCE)" "$$tmp/destination/$$name"; \
	echo 'recursive verification: ok'

display:
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -e "$(SOURCE)" || (echo "SOURCE does not exist: $(SOURCE)"; exit 2)
	@if [ -d "$(SOURCE)" ]; then \
		find "$(SOURCE)" -exec stat --printf='Path: %n\nType: %F\nFile size: %s bytes\nMode: %a\nUID: %u\nGID: %g\nModified: %y\n\n' {} +; \
	else \
		stat --printf='Path: %n\nType: %F\nFile size: %s bytes\nMode: %a\nUID: %u\nGID: %g\nModified: %y\n\n' "$(SOURCE)"; \
	fi

help:
	@echo 'Usage:'
	@echo '  make copy SOURCE=source DEST=destination'
	@echo '  make copy-paste SOURCE=source DEST=destination'
	@echo '  make recursive SOURCE=directory DEST=directory'
	@echo '  make preserve SOURCE=source DEST=destination'
	@echo '  make log SOURCE=source DEST=destination LOG=path-to-log'
	@echo '  make display SOURCE=file-or-directory'
	@echo '  make verify-recursive SOURCE=directory'
	@echo '  make integration       run end-to-end shell tests'
	@echo '  make gtest             run GoogleTest unit tests'
	@echo '  make valgrind          check for memory errors on Linux'
	@echo '  make coverage          generate gcov coverage data'
	@echo '  make misra             run MISRA-oriented Cppcheck analysis'
	@echo '  make test-all          run all quality checks'
	@echo '  make backup SOURCE=source DEST=destination'
	@echo '  make sync SOURCE=directory DEST=directory'
	@echo '  make all-features SOURCE=source DEST=destination LOG=mycp.log'
	@echo '  add BUFFER=512, 1024, 2048, or 4096 to choose the buffer size'
	@echo ''
	@echo 'Targets:'
	@echo '  copy          copy files or directories with progress and verification'
	@echo '  recursive     recursively copy a directory with verification'
	@echo '  backup        copy with resume support'
	@echo '  sync          recursive incremental synchronization'
	@echo '  all-features  enable every available command-line feature'
	@echo '  verify        run the automated verification tests'
	@echo '  display       show file or directory information without copying'

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
		echo '  512  1024  2048  4096'; \
		printf 'Buffer size [1024]: '; \
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

preserve: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	./mycp -r --buffer "$(BUFFER)" --preserve --progress --verify \
		"$(SOURCE)" "$(DEST)"

log: mycp
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	./mycp $(COMMON_FLAGS) --verbose --log "$(LOG)" \
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
