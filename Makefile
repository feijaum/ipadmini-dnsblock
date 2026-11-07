CC ?= cc
CFLAGS ?= -O2
WARNINGS = -Wall -Wextra -Werror

.PHONY: all test ios clean
all: build/dnsblock

build/dnsblock: src/dnsblock.c
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -std=c99 -pthread $< $(LDFLAGS) -o $@

test: build/dnsblock
	python3 -m unittest discover -s tests -v

ios:
	bash scripts/build-ios.sh

clean:
	rm -rf build dist
