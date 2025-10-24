#!/bin/bash

# Generate filtered coverage report for src/vaults and src/distributor only
# Usage: ./scripts/coverage-filtered.sh [profile]
# Example: ./scripts/coverage-filtered.sh ci

set -e

PROFILE=${1:-default}

echo "📊 Generating full coverage report (profile: $PROFILE)..."
FOUNDRY_PROFILE=$PROFILE forge coverage --report lcov --report-file lcov-full.info

echo "🔍 Filtering to src/vaults and src/distributor only..."
lcov --extract lcov-full.info 'src/vaults/*' 'src/distributor/*' --output-file lcov-filtered.info --rc branch_coverage=1 --ignore-errors inconsistent 2>/dev/null
cp lcov-filtered.info lcov.info

echo ""
echo "📈 Filtered Coverage Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
lcov --list lcov.info --rc branch_coverage=1 --ignore-errors inconsistent 2>/dev/null

echo ""
echo "✓ Filtered coverage report saved to lcov.info"
echo "✓ Full unfiltered report saved to lcov-full.info"
echo "✓ Coverage Gutters extension will now show filtered coverage"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Additional commands:"
echo "  View detailed report:  lcov --list lcov.info --rc lcov_branch_coverage=1 --ignore-errors inconsistent 2>/dev/null"
echo "  Generate HTML report:  genhtml lcov.info --output-directory coverage-html --rc lcov_branch_coverage=1 --ignore-errors inconsistent"
echo "  Open HTML report:      open coverage-html/index.html"
echo "  Run with CI profile:   ./scripts/coverage-filtered.sh ci"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

