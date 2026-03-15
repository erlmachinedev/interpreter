PROJECT = interpreter
PROJECT_DESCRIPTION = "Lua 5.2 interpreter embedded in ERTS"
PROJECT_VERSION = 0.0.1

LOCAL_DEPS = syntax_tools

TEST_DEPS = meck

dep_meck = git https://github.com/eproxus/meck.git

include erlang.mk
