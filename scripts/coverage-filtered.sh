#!/bin/bash

# Generate filtered coverage report for src/vaults and src/distributor only
# Usage: ./scripts/coverage-filtered.sh

set -e

echo "📊 Generating full coverage report..."
forge coverage --report lcov --report-file lcov-full.info

echo "🔍 Filtering to src/vaults and src/distributor only..."
lcov --extract lcov-full.info 'src/vaults/*' 'src/distributor/*' --output-file lcov.info --rc lcov_branch_coverage=1 2>/dev/null

echo ""
echo "📈 Filtered Coverage Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
lcov --list lcov.info 2>/dev/null

echo ""
echo "✓ Filtered coverage report saved to lcov.info"
echo "✓ Coverage Gutters extension will now show filtered coverage"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Additional commands:"
echo "  View detailed report:  lcov --list lcov.info"
echo "  Generate HTML report:  genhtml lcov.info --output-directory coverage-html"
echo "  Open HTML report:      open coverage-html/index.html"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

