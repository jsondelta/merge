build: build-wasm ## Build all targets

build-wasm: ## Compile Zig to WebAssembly
	cd zig && zig build -Doptimize=ReleaseSmall
	cp zig/zig-out/bin/merge.wasm wasm/merge.wasm

types: ## Generate TypeScript declarations from JSDoc
	npx tsc --declaration --allowJs --emitDeclarationOnly --skipLibCheck --target es2020 --module nodenext --moduleResolution nodenext --strict false --esModuleInterop true --outDir ./types src/index.js src/fallback.js src/wasm.js

clean: ## Remove build artifacts
	rm -rf zig/zig-out zig/.zig-cache wasm/merge.wasm types/

test: build ## Build and run tests
	npm test

.PHONY: build build-wasm types clean test help

help: ## Show help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[32m%-20s\033[0m %s\n", $$1, $$2}'
