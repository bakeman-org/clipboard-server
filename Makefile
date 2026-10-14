run:
	-rebar3 compile
	-rebar3 shell

___prepare_sqlite3:
	curl -JLO https://gh-proxy.org/https://raw.githubusercontent.com/clibs/sqlite/master/sqlite3.h
	curl -JLO https://gh-proxy.org/https://raw.githubusercontent.com/clibs/sqlite/master/sqlite3.c