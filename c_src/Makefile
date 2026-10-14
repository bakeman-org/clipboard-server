ERTS_VSN      := $(shell erl -noshell -eval 'io:format("~s", [erlang:system_info(version)]), halt().')
ERL_ROOT      := $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
ERTS_INCLUDE  := $(ERL_ROOT)/erts-$(ERTS_VSN)/include

# -Wall -Wextra -Wno-return-local-addr -Wno-unused-const-variable
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

.PHONY: all clean

__print_erlang_env:
	@echo "ERL_ROOT     = $(ERL_ROOT)"
	@echo "ERTS_VSN     = $(ERTS_VSN)"
	@echo "ERTS_INCLUDE = $(ERTS_INCLUDE)"
	@ls -la $(ERTS_INCLUDE)/erl_nif.h