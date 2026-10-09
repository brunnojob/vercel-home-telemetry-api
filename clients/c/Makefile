CC ?= cc
CFLAGS ?= -O2 -std=c17 -Wall -Wextra -Werror
LDLIBS = -lcjson -lcurl -lcrypto
all: archive
archive: archive.c
	$(CC) $(CPPFLAGS) $(CFLAGS) archive.c $(LDFLAGS) $(LDLIBS) -o archive
test: archive
	$(CC) $(CPPFLAGS) $(CFLAGS) -Wno-unused-function test.c $(LDFLAGS) $(LDLIBS) -o archive-test
	./archive-test
clean:
	rm -f archive archive-test
.PHONY: all test clean
