# findmy - build and check

build:
    swiftc -O findmy.swift -o findmy

test:
    swiftc -Onone findmy.swift -o findmy && ./findmy --selftest

check:
    swiftc -typecheck findmy.swift

run *ARGS: build
    ./findmy {{ARGS}}
