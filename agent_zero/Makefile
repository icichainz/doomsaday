BINARY      := agent_zero
VERSION     ?= $(shell cat VERSION 2>/dev/null || echo 0.1.0)
LDFLAGS     := -s -w -X agent_zero/internal/version.Version=$(VERSION)
DEV_DATA    ?= ./.devdata
DEV_LISTEN  ?= :8443

.PHONY: all build test vet fmt fmt-check lint race run-dev clean docker tidy check

all: check build

## build: compile the single binary into ./bin
build:
	@mkdir -p bin
	go build -trimpath -ldflags '$(LDFLAGS)' -o bin/$(BINARY) ./cmd/agent_zero
	@echo "built bin/$(BINARY) $(VERSION)"

## test: run the unit tests with the race detector
test:
	go test ./... -race

## vet: run go vet
vet:
	go vet ./...

## fmt: rewrite every file with gofmt
fmt:
	gofmt -w .

## fmt-check: fail when anything is unformatted
fmt-check:
	@out=$$(gofmt -l .); \
	if [ -n "$$out" ]; then echo "not gofmt clean:"; echo "$$out"; exit 1; fi
	@echo "gofmt clean"

## check: everything CI should run
check: fmt-check vet test

## race: alias for test
race: test

## tidy: refresh go.mod and go.sum
tidy:
	go mod tidy

## run-dev: run against the local daemon over plain HTTP in a throwaway data dir
run-dev: build
	@mkdir -p $(DEV_DATA)
	@chmod 700 $(DEV_DATA)
	./bin/$(BINARY) \
		--listen $(DEV_LISTEN) \
		--data-dir $(DEV_DATA) \
		--stacks-dir $(DEV_DATA)/stacks \
		--insecure-http \
		--log-level debug

## docker: build the container image
docker:
	docker build -t agent_zero:$(VERSION) .

clean:
	rm -rf bin $(DEV_DATA)
