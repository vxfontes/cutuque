.PHONY: run test build tidy

run:
	go run ./cmd/hub

test:
	go test ./...

build:
	go build -o bin/hub ./cmd/hub

tidy:
	go mod tidy
