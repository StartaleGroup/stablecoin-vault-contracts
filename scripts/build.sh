#!/bin/bash

# Build script with automatic dependency resolution
# Usage: ./scripts/build.sh [--reinstall-deps]

set -e  # Exit on any error

REINSTALL_DEPS=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --reinstall-deps)
      REINSTALL_DEPS=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--reinstall-deps]"
      echo "  --reinstall-deps    Force reinstall all git submodule dependencies"
      echo "  -h, --help         Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

echo "🔨 Building stablecoin contracts..."

# Check if we should reinstall dependencies
if [[ "$REINSTALL_DEPS" == "true" ]]; then
  echo "🔄 Force reinstalling dependencies..."
  ./scripts/reinstall-deps.sh
else
  # Try a regular build first
  echo "🏗️  Attempting build..."
  if ! forge build 2>/dev/null; then
    echo "⚠️  Build failed, likely due to missing dependencies"
    echo "🔄 Reinstalling dependencies and retrying..."
    ./scripts/reinstall-deps.sh
  else
    echo "✅ Build successful!"
  fi
fi

echo "🎉 Build completed successfully!"