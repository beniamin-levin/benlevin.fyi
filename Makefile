.PHONY: tidy build build-linux run test

tidy:
	go mod tidy

build:
	go build -o bin/server ./cmd/server

build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o bin/server-linux ./cmd/server

run:
	go run ./cmd/server

test:
	go test ./...
