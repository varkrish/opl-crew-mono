.PHONY: build build-all clean test

APP_NAME=opl-cli
DIST_DIR=dist

build:
	@echo "🔨 Building $(APP_NAME) for current OS..."
	@go build -o $(APP_NAME) main.go
	@echo "✅ Done! You can run it with ./$(APP_NAME)"

build-all: clean
	@echo "📦 Building for Mac (Apple Silicon)..."
	@GOOS=darwin GOARCH=arm64 go build -o $(DIST_DIR)/$(APP_NAME)-darwin-arm64 main.go
	@echo "📦 Building for Mac (Intel)..."
	@GOOS=darwin GOARCH=amd64 go build -o $(DIST_DIR)/$(APP_NAME)-darwin-amd64 main.go
	@echo "📦 Building for Linux (x86_64)..."
	@GOOS=linux GOARCH=amd64 go build -o $(DIST_DIR)/$(APP_NAME)-linux-amd64 main.go
	@echo "📦 Building for Windows..."
	@GOOS=windows GOARCH=amd64 go build -o $(DIST_DIR)/$(APP_NAME)-windows-amd64.exe main.go
	@echo "✅ All cross-platform builds complete! Find them in $(DIST_DIR)/"

clean:
	@echo "🧹 Cleaning up..."
	@rm -rf $(DIST_DIR)
	@rm -f $(APP_NAME)

test:
	@go test ./...
