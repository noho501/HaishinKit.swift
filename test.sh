#!/bin/bash

# 🚀 HaishinKit Optimization Testing Script
# Usage: ./test.sh [target]
# Targets: build, run, profile, clean

set -e

PROJECT_PATH="/Users/dt_hiephoang/HaishinKit.swift"
EXAMPLES_PATH="$PROJECT_PATH/Examples"
SCHEME="HaishinApp"
CONFIG="Debug"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Functions
print_header() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# Main
cd "$EXAMPLES_PATH"

TARGET=${1:-build}

case $TARGET in
    build)
        print_header "📦 Building HaishinKit Example"
        print_info "Scheme: $SCHEME"
        print_info "Config: $CONFIG"
        
        xcodebuild \
            -scheme "$SCHEME" \
            -configuration "$CONFIG" \
            -destination "generic/platform=iOS" \
            build
        
        print_success "Build completed successfully!"
        ;;
        
    clean)
        print_header "🧹 Cleaning Project"
        xcodebuild clean -scheme "$SCHEME"
        print_success "Clean completed!"
        ;;
        
    profile)
        print_header "📊 Profiling Performance"
        print_info "Opening Instruments..."
        open -a "Instruments"
        print_info "1. Select 'System Trace' template"
        print_info "2. Click 'Choose' and select built app"
        print_info "3. Run streaming for 30-60 seconds"
        print_info "4. Stop recording and analyze"
        ;;
        
    open)
        print_header "🎯 Opening Xcode Project"
        open "$EXAMPLES_PATH/Examples.xcodeproj"
        ;;
        
    git-status)
        print_header "📋 Git Status"
        cd "$PROJECT_PATH"
        git status --short
        echo ""
        git diff --stat
        ;;
        
    verify)
        print_header "✅ Verifying Changes"
        cd "$PROJECT_PATH"
        print_info "Checking VideoCodec.swift..."
        grep -A 2 "useFrame" HaishinKit/Sources/Codec/VideoCodec.swift | head -5
        print_success "Changes verified!"
        ;;
        
    *)
        echo "Usage: $0 [build|clean|profile|open|git-status|verify]"
        echo ""
        echo "Commands:"
        echo "  build      - Build the project"
        echo "  clean      - Clean build folder"
        echo "  profile    - Open Instruments for profiling"
        echo "  open       - Open Xcode project"
        echo "  git-status - Show git status"
        echo "  verify     - Verify optimization changes"
        exit 1
        ;;
esac

print_success "Done!"
