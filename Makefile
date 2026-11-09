CC ?= cc
CXX ?= c++
CPPCHECK ?= cppcheck
VALGRIND ?= valgrind
GCOV ?= gcov
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wpedantic
CPPFLAGS ?= -Iinclude
LDFLAGS ?=

BUILD_DIR ?= build
COVERAGE_DIR ?= coverage
SRC_DIR ?= src
INCLUDE_DIR ?= include
TEST_DIR ?= test
MYCP := $(BUILD_DIR)/mycp

GTEST_CFLAGS ?= $(shell pkg-config --cflags gtest_main 2>/dev/null)
GTEST_LIBS ?= $(shell pkg-config --libs gtest_main 2>/dev/null)
GTEST_FS_LIBS ?= $(shell test -f "$(shell $(CXX) -print-file-name=libstdc++fs.a 2>/dev/null)" && echo -lstdc++fs)
ifeq ($(strip $(GTEST_LIBS)),)
GTEST_LIBS := -lgtest_main -lgtest -pthread
endif

.PHONY: all clean test verify verify-recursive integration gtest valgrind coverage cppcheck misra misra-platform test-all display help copy copy-paste recursive preserve backup log sync all-features

SOURCE ?=
FILE ?=
DEST ?=
LOG ?=
BUFFER ?= 1024

DEST_BASE = $(patsubst %/,%,$(DEST))
SOURCE_BASE = $(notdir $(patsubst %/,%,$(SOURCE)))
DEST_LOG = $(if $(shell test -d "$(DEST)" && echo yes),$(DEST_BASE)/$(SOURCE_BASE).log,$(DEST_BASE).log)
LOG_PATH = $(if $(strip $(LOG)),$(LOG),$(DEST_LOG))
DISPLAY_FILE = $(if $(strip $(FILE)),$(FILE),$(SOURCE))
COMMON_FLAGS = -r --buffer $(BUFFER) --preserve --progress --verify --benchmark --resume --log "$(LOG_PATH)"

all: $(MYCP)

mycp: $(MYCP)

$(BUILD_DIR):
	mkdir -p $@

$(MYCP): $(SRC_DIR)/mycp.c $(SRC_DIR)/mycp_core.c $(INCLUDE_DIR)/mycp_core.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $(SRC_DIR)/mycp.c $(SRC_DIR)/mycp_core.c $(LDFLAGS)

test: $(MYCP)
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	printf 'hello low-level backup\n' > "$$tmp/source"; chmod 640 "$$tmp/source"; \
	$(MYCP) --preserve --verify --benchmark "$$tmp/source" "$$tmp/dest"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/dest")"; \
	test "$$(stat -c %a "$$tmp/source")" = "$$(stat -c %a "$$tmp/dest")"; \
	mkdir -p "$$tmp/tree/nested/deeper"; printf 'nested\n' > "$$tmp/tree/a"; printf 'deep\n' > "$$tmp/tree/nested/deeper/file"; $(MYCP) -r --verify "$$tmp/tree" "$$tmp/out"; \
	test -f "$$tmp/out/a"; test "$$(cat "$$tmp/out/a")" = nested; \
	test -f "$$tmp/out/nested/deeper/file"; test "$$(cat "$$tmp/out/nested/deeper/file")" = deep; \
	printf 'hello l' > "$$tmp/partial"; chmod 444 "$$tmp/partial"; $(MYCP) --resume "$$tmp/source" "$$tmp/partial"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/partial")"; \
	printf 'wrong' > "$$tmp/mismatch"; $(MYCP) --resume "$$tmp/source" "$$tmp/mismatch"; \
	test "$$(cat "$$tmp/source")" = "$$(cat "$$tmp/mismatch")"; echo 'tests: ok'

verify: test

integration: $(MYCP)
	MYCP=$(MYCP) sh $(TEST_DIR)/integration.sh

gtest: $(MYCP)
	@mkdir -p $(BUILD_DIR)
	$(CXX) -std=c++17 -Wall -Wextra -Wpedantic $(GTEST_CFLAGS) \
		test/mycp_gtest.cpp $(GTEST_LIBS) $(GTEST_FS_LIBS) -o $(BUILD_DIR)/mycp_gtest
	MYCP=$(MYCP) $(BUILD_DIR)/mycp_gtest

valgrind: $(MYCP)
	@command -v $(VALGRIND) >/dev/null 2>&1 || (echo "Valgrind not found: $(VALGRIND)"; exit 2)
	MYCP=$(MYCP) VALGRIND=$(VALGRIND) sh $(TEST_DIR)/valgrind.sh

coverage:
	@rm -rf $(COVERAGE_DIR)
	@mkdir -p $(COVERAGE_DIR)
	@touch $(COVERAGE_DIR)/.gitkeep
	@rm -f mycp.gcda mycp.gcno mycp_core.gcda mycp_core.gcno core_coverage.gcda core_coverage.gcno *.gcov
	$(CC) -O0 -g -std=c11 -Wall -Wextra -Wpedantic --coverage \
		$(CPPFLAGS) -c $(SRC_DIR)/mycp.c -o $(COVERAGE_DIR)/mycp.o
	$(CC) -O0 -g -std=c11 -Wall -Wextra -Wpedantic --coverage \
		$(CPPFLAGS) -c $(SRC_DIR)/mycp_core.c -o $(COVERAGE_DIR)/mycp_core.o
	$(CC) -O0 -g -std=c11 -Wall -Wextra -Wpedantic --coverage \
		$(LDFLAGS) -o $(COVERAGE_DIR)/mycp $(COVERAGE_DIR)/mycp.o $(COVERAGE_DIR)/mycp_core.o
	MYCP=./$(COVERAGE_DIR)/mycp sh $(TEST_DIR)/integration.sh
	MYCP=./$(COVERAGE_DIR)/mycp sh $(TEST_DIR)/coverage_extra.sh
	$(CC) -O0 -g -std=c11 -Wall -Wextra -Wpedantic --coverage \
		$(CPPFLAGS) -c $(TEST_DIR)/core_coverage.c -o $(COVERAGE_DIR)/core_coverage.o
	$(CC) -O0 -g -std=c11 -Wall -Wextra -Wpedantic --coverage \
		$(CPPFLAGS) -c $(SRC_DIR)/mycp_core.c -o $(COVERAGE_DIR)/core_mycp_core.o
	$(CC) -O0 -g -std=c11 -Wall -Wextra -Wpedantic --coverage \
		$(LDFLAGS) -o $(COVERAGE_DIR)/core_coverage \
		$(COVERAGE_DIR)/core_coverage.o $(COVERAGE_DIR)/core_mycp_core.o
	./$(COVERAGE_DIR)/core_coverage
	@set -eu; \
	for source in $(SRC_DIR)/mycp.c $(SRC_DIR)/mycp_core.c $(TEST_DIR)/core_coverage.c; do \
		$(GCOV) -b -c -o $(COVERAGE_DIR) "$$source" || true; \
	done; \
	if ! find . -maxdepth 1 -name '*.gcov' -print -quit | grep -q .; then \
		for notes in $$(find $(COVERAGE_DIR) -maxdepth 1 -name '*.gcno' -print); do \
			$(GCOV) -b -c -o $(COVERAGE_DIR) "$$notes" || true; \
		done; \
	fi; \
	for report in *.gcov; do \
		if [ -f "$$report" ]; then mv -f "$$report" $(COVERAGE_DIR)/; fi; \
	done; \
	test -n "$$(find $(COVERAGE_DIR) -maxdepth 1 -name '*.gcov' -print -quit)"
	@echo 'coverage: generated reports in $(COVERAGE_DIR)/'

misra:
	@command -v $(CPPCHECK) >/dev/null 2>&1 || (echo "Cppcheck not found: $(CPPCHECK)"; exit 2)
	$(CPPCHECK) $(CPPFLAGS) --enable=all --inconclusive --error-exitcode=1 \
		--std=c11 --addon=misra --suppress=missingIncludeSystem \
		--suppress=unusedFunction --suppress=misra-c2012-8.7 \
		--suppress=unmatchedSuppression \
		$(SRC_DIR)/mycp_core.c

cppcheck:
	@command -v $(CPPCHECK) >/dev/null 2>&1 || (echo "Cppcheck not found: $(CPPCHECK)"; exit 2)
	$(CPPCHECK) $(CPPFLAGS) --enable=warning,style,performance,portability \
		--inconclusive --std=c11 --suppress=missingIncludeSystem \
		$(SRC_DIR)/mycp.c $(SRC_DIR)/mycp_core.c

misra-platform:
	@command -v $(CPPCHECK) >/dev/null 2>&1 || (echo "Cppcheck not found: $(CPPCHECK)"; exit 2)
	@echo 'Linux adapter MISRA audit; findings are documented in MISRA_DEVIATIONS.md'
	$(CPPCHECK) $(CPPFLAGS) --enable=all --inconclusive --std=c11 --addon=misra \
		--suppress=missingIncludeSystem $(SRC_DIR)/mycp.c

test-all: integration gtest valgrind coverage cppcheck misra

verify-recursive: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE directory is required'; exit 2)
	@test -d "$(SOURCE)" || (echo "SOURCE is not a directory: $(SOURCE)"; exit 2)
	@set -eu; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	mkdir -p "$$tmp/destination"; \
	$(MYCP) -r --buffer "$(BUFFER)" --preserve --progress --verify \
		"$(SOURCE)" "$$tmp/destination"; \
	name=$$(basename -- "$(SOURCE)"); \
	diff -r "$(SOURCE)" "$$tmp/destination/$$name"; \
	echo 'recursive verification: ok'

display:
	@test -n "$(DISPLAY_FILE)" || (echo 'FILE is required'; exit 2)
	@test -e "$(DISPLAY_FILE)" || (echo "File does not exist: $(DISPLAY_FILE)"; exit 2)
	@if [ -d "$(DISPLAY_FILE)" ]; then \
		find "$(DISPLAY_FILE)" -exec stat --printf='Path: %n\nType: %F\nFile size: %s bytes\nMode: %a\nUID: %u\nGID: %g\nModified: %y\n\n' {} +; \
	else \
		stat --printf='Path: %n\nType: %F\nFile size: %s bytes\nMode: %a\nUID: %u\nGID: %g\nModified: %y\n\n' "$(DISPLAY_FILE)"; \
	fi

help:
	@echo 'Usage:'
	@echo '  make copy SOURCE=source DEST=destination'
	@echo '  make copy-paste SOURCE=source DEST=destination'
	@echo '  make recursive SOURCE=directory DEST=directory'
	@echo '  make preserve SOURCE=source DEST=destination'
	@echo '  make log SOURCE=source DEST=destination LOG=path-to-log'
	@echo '  make display FILE=file-or-directory'
	@echo '  make verify-recursive SOURCE=directory'
	@echo '  make integration       run end-to-end shell tests'
	@echo '  make gtest             run GoogleTest unit tests'
	@echo '  make valgrind          check for memory errors on Linux'
	@echo '  make coverage          generate gcov coverage data'
	@echo '  make misra             run MISRA-oriented Cppcheck analysis'
	@echo '  make cppcheck          run standard Cppcheck analysis'
	@echo '  make misra-platform    report Linux/POSIX adapter deviations'
	@echo '  make test-all          run all quality checks'
	@echo '  make backup SOURCE=source DEST=destination'
	@echo '  make sync SOURCE=directory DEST=directory'
	@echo '  make all-features SOURCE=source DEST=destination LOG=mycp.log'
	@echo '  add BUFFER=512, 1024, 2048, or 4096 to choose the buffer size'
	@echo '  override tools with CPPCHECK=, VALGRIND=, GCOV=, GTEST_CFLAGS=, GTEST_LIBS=, GTEST_FS_LIBS='
	@echo ''
	@echo 'Targets:'
	@echo '  copy          copy files or directories with progress and verification'
	@echo '  recursive     recursively copy a directory with verification'
	@echo '  backup        copy with resume support'
	@echo '  sync          recursive incremental synchronization'
	@echo '  all-features  enable every available command-line feature'
	@echo '  verify        run the automated verification tests'
	@echo '  display       show file or directory information without copying'

copy: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	$(MYCP) $(COMMON_FLAGS) "$(SOURCE)" "$(DEST)"

copy-paste: $(MYCP)
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
	$(MYCP) -r --preserve --progress --verify --benchmark --resume --log "$(LOG_PATH)" --buffer "$$buffer" \
		"$(SOURCE)" "$(DEST)"

recursive: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE directory is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST directory is required'; exit 2)
	$(MYCP) -r --buffer "$(BUFFER)" --preserve --progress --verify --benchmark --resume --log "$(LOG_PATH)" \
		"$(SOURCE)" "$(DEST)"

preserve: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	$(MYCP) -r --buffer "$(BUFFER)" --preserve --progress --verify --benchmark --resume --log "$(LOG_PATH)" \
		"$(SOURCE)" "$(DEST)"

log: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	$(MYCP) $(COMMON_FLAGS) --verbose \
		"$(SOURCE)" "$(DEST)"

backup: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	$(MYCP) $(COMMON_FLAGS) --resume "$(SOURCE)" "$(DEST)"

sync: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	$(MYCP) -r $(COMMON_FLAGS) --resume --sync --benchmark \
		"$(SOURCE)" "$(DEST)"

all-features: $(MYCP)
	@test -n "$(SOURCE)" || (echo 'SOURCE is required'; exit 2)
	@test -n "$(DEST)" || (echo 'DEST is required'; exit 2)
	$(MYCP) -r --buffer "$(BUFFER)" --preserve --progress --verify --resume --info \
		--benchmark --sync --verbose --log "$(LOG_PATH)" \
		"$(SOURCE)" "$(DEST)"


clean:
	rm -rf $(BUILD_DIR) $(COVERAGE_DIR)
