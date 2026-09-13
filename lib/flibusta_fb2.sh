# Flibusta FB2 extraction functions.
#
# This module deliberately contains no database access. Database functions can
# be introduced later as a separate dependency without changing the archive
# extraction primitives.
# -----------------------------------------------------------------------------

validate_file_number() {
    local file_number="$1"

    [[ "$file_number" =~ ^[0-9]+$ ]] ||
        die "Invalid FileNumber: '$file_number' (expected digits only)"

    (( 10#$file_number > 0 )) ||
        die "Invalid FileNumber: '$file_number' (must be greater than zero)"
}

find_fb2_archive() {
    local file_number="$1"
    local archive
    local base_name
    local start_number
    local end_number

    shopt -s nullglob

    for archive in "$FLIBUSTA_SOURCE_DIR"/f.fb2-*.zip; do
        base_name="$(basename "$archive")"

        if [[ "$base_name" =~ ^f\.fb2-([0-9]+)-([0-9]+)\.zip$ ]]; then
            start_number="${BASH_REMATCH[1]}"
            end_number="${BASH_REMATCH[2]}"

            if (( 10#$start_number <= 10#$file_number &&
                  10#$file_number <= 10#$end_number )); then
                printf '%s\n' "$archive"
                return 0
            fi
        fi
    done

    return 1
}

extract_fb2_file() {
    local archive="$1"
    local file_number="$2"
    local output_file="$3"
    local member="${file_number}.fb2"
    local temp_file

    mkdir -p "$FB2_OUTPUT_DIR"

    temp_file="${output_file}.tmp.$$"

    if ! unzip -p "$archive" "$member" > "$temp_file"; then
        rm -f -- "$temp_file"
        die "Failed to extract '$member' from '$archive'"
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f -- "$temp_file"
        die "Extracted file is empty: '$member'"
    fi

    mv -- "$temp_file" "$output_file"
}

main() {
    local file_number="${1:-}"
    local archive
    local output_file

    if [[ $# -ne 1 ]]; then
        printf 'Usage: %s FILE_NUMBER\n' "$(basename "$0")" >&2
        return 2
    fi

    validate_file_number "$file_number"

    require_command unzip
    [[ -d "$FLIBUSTA_SOURCE_DIR" ]] ||
        die "Source directory does not exist: $FLIBUSTA_SOURCE_DIR"

    archive="$(find_fb2_archive "$file_number")" ||
        die "No FB2 archive contains FileNumber $file_number"

    output_file="$FB2_OUTPUT_DIR/${file_number}.fb2"

    printf 'Archive : %s\n' "$archive"
    printf 'Member  : %s.fb2\n' "$file_number"
    printf 'Output  : %s\n' "$output_file"

    extract_fb2_file "$archive" "$file_number" "$output_file"

    printf 'Done.\n'
}

# Minimal local helpers; replace with project-wide common.sh functions when
# this utility is integrated with the repository's shared infrastructure.
die() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}
