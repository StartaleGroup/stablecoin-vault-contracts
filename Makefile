# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# dapp deps
update:; forge update

# Deployment helpers
deploy-local :; FOUNDRY_PROFILE=production forge script script/Deploy.s.sol --rpc-url localhost --broadcast -v
deploy-sepolia :; FOUNDRY_PROFILE=production forge script script/Deploy.s.sol --rpc-url sepolia --broadcast -vvv

# Run slither
slither :; FOUNDRY_PROFILE=production forge build --build-info --skip '*/test/**' --skip '*/script/**' --force && slither --compile-force-framework foundry --ignore-compile --sarif results.sarif --config-file slither.config.json .

# Common tasks
profile ?=default

build:
	@./build.sh -p production

tests:
	@./test.sh -p $(profile)

fuzz:
	@./test.sh -t testFuzz -p $(profile)

integration:
	@./test.sh -d test/integration -p $(profile)

invariant:
	@./test.sh -d test/invariant -p $(profile)

coverage:
	FOUNDRY_PROFILE=$(profile) forge coverage --report lcov

coverage-filtered:
	@echo "📊 Generating full coverage report..."
	@FOUNDRY_PROFILE=$(profile) forge coverage --report lcov --report-file lcov-full.info
	@echo "🔍 Filtering to src/vaults and src/distributor only..."
	@lcov --extract lcov-full.info 'src/vaults/*' 'src/distributor/*' --output-file lcov-filtered.info --rc branch_coverage=1 --ignore-errors inconsistent 2>/dev/null
	@cp lcov-filtered.info lcov.info
	@echo ""
	@echo "📈 Filtered Coverage Summary:"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@./scripts/coverage-summary.sh lcov.info
	@echo ""
	@echo "✓ Filtered coverage saved to lcov.info (for Coverage Gutters)"
	@echo "✓ Full coverage saved to lcov-full.info"
	@echo ""
	@echo "💡 To generate HTML report: make coverage-html"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

coverage-html:
	@echo "🌐 Generating HTML coverage report..."
	@genhtml lcov.info --output-directory coverage-html --rc branch_coverage=1 --ignore-errors inconsistent --quiet
	@echo "✅ HTML report generated in coverage-html/"
	@echo "📂 Open with: open coverage-html/index.html"
	@open coverage-html/index.html 2>/dev/null || echo "   (Run 'open coverage-html/index.html' to view)"

gas-report:
	FOUNDRY_PROFILE=$(profile) forge test --gas-report > gasreport.ansi

sizes:
	@./build.sh -p production -s

clean:
	forge clean && rm -rf ./abi && rm -rf ./bytecode && rm -rf ./types
