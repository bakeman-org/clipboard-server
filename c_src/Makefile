# Pull precomputed Erlang paths (run ./env.sh first).
-include config.mk

# Fail loudly if config.mk is missing/stale.
ifeq ($(ERTS_INCLUDE),)
$(error ERTS_INCLUDE is empty — run ./env.sh first to generate config.mk)
endif

CFLAGS   := -std=c11 -O2 -fPIC -I$(ERTS_INCLUDE)
LDFLAGS  := -shared

TARGET   := ../priv/clipboard_sqlite_nif.so
SOURCES  := clipboard_sqlite_nif.c sqlite3.c

all: $(TARGET)

$(TARGET): $(SOURCES)
	@mkdir -p ../priv
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES)

clean:
	-rm -f $(TARGET)

.PHONY: all clean config debug

# Regenerate config.mk on demand (also outside Bear).
config:
	@./env.sh

debug: config.mk
	@echo "ERL_ROOT     = $(ERL_ROOT)"
	@echo "ERTS_VSN     = $(ERTS_VSN)"
	@echo "ERTS_INCLUDE = $(ERTS_INCLUDE)"
	@ls -la $(ERTS_INCLUDE)/erl_nif.h