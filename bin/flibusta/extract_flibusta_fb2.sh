#!/usr/bin/env bash
#
# Title: Extract Flibusta FB2
# Script Name: extract_flibusta_fb2.sh
# Description: Locate the Flibusta FB2 range archive containing a file number
#              and extract only that FB2 file into the configured ToLoad folder.
# Project: ebook-library-tools-next
# Author: mp
# Date: 2026-09-13
# Version: 0.1.0
#
# Usage:
#   extract_flibusta_fb2.sh FILE_NUMBER
#
# Notes:
#   Stage 1 only. Database integration and subsequent FB2 processing are
#   intentionally outside the scope of this initial implementation.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../config/flibusta_fb2.conf
source "$PROJECT_ROOT_DIR/config/flibusta_fb2.conf"

# shellcheck source=../../lib/flibusta_fb2.sh
source "$PROJECT_ROOT_DIR/lib/flibusta_fb2.sh"

main "$@"
