#!/bin/bash

# Reinstall all git submodule dependencies
# This script removes the lib directory and reinstalls all submodules from scratch

set -e  # Exit on any error

echo "🔄 Reinstalling all dependencies..."
echo "📦 Removing existing lib directory..."
rm -rf lib

echo "⬇️  Installing git submodules..."
git submodule update --init --recursive --force

echo "✅ Dependencies reinstalled successfully!"
echo "🔨 Running forge build to verify installation..."
forge build

echo "🎉 All done! Dependencies are ready to use."