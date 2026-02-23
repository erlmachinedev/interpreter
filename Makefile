PROJECT = interpreter
PROJECT_DESCRIPTION = "Embedded program to execute Lua code"
PROJECT_VERSION = 0.0.1

DEPS = horus

dep_horus = hex 0.3.2

TEST_DEPS = meck

dep_meck = git https://github.com/eproxus/meck.git

include erlang.mk
