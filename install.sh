#!/bin/sh
# chezmoi install script
# contains code from and inspired by
# https://githubfast.com/client9/shlib
# https://githubfast.com/goreleaser/godownloader

# --- Script Setup ---
# Exit immediately if a command exits with a non-zero status.
set -e

# --- Global Variables ---
# BINDIR: Directory for installation. Can be overridden by environment variable. Defaults to 'bin'.
BINDIR="${BINDIR:-bin}"
# TAGARG: The tag to install. Defaults to 'latest'.
TAGARG=latest
# LOG_LEVEL: Verbosity of the script's output. 0=crit, 1=err, 2=info, 3=debug.
LOG_LEVEL=2

# --- Temporary Directory Setup and Cleanup ---
# Create a temporary directory for downloads.
tmpdir="$(mktemp -d)"
# Register cleanup routines to remove the temporary directory on exit or interruption.
trap 'rm -rf -- "${tmpdir}"' EXIT
trap 'exit' INT TERM

# --- Function Definitions ---

# Shows usage information and exits.
usage() {
    this="${1}"
    cat <&2
    return 1
    ;;
esac
}

# Determines the system's C standard library (libc).
# It checks for glibc or musl and handles version checks for glibc.
get_libc() {
    if is_command ldd; then
        case "$(ldd --version 2>&1 | tr '[:upper:]' '[:lower:]')" in
            *glibc* | *"gnu libc"*)
                # If the version of glibc is too old then use the statically-linked
                # musl version instead. chezmoi releases are built on GitHub Actions
                # ubuntu-22.04 runners, which have glibc version 2.35.
                minimum_glibc_version=2.35
                glibc_version="$(ldd --version 2>&1 | awk '$1 == "ldd" { print $NF }')"
                # shellcheck disable=SC2046,SC2183
                minimum_glibc_version_string="$(printf "%03d%03d" $(echo "${minimum_glibc_version}" | tr "." " "))"
                # shellcheck disable=SC2046,SC2183
                glibc_version_string="$(printf "%03d%03d" $(echo "${glibc_version}" | tr "." " "))"

                log_info "found glibc version ${glibc_version}"

                if [ "${glibc_version_string}" -lt "${minimum_glibc_version_string}" ]; then
                    printf musl
                    return
                fi
                printf glibc
                return
                ;;
            *musl*)
                printf musl
                return
                ;;
        esac
    fi

    if is_command getconf; then
        case "$(getconf GNU_LIBC_VERSION 2>&1)" in
            *glibc*)
                printf glibc
                return
                ;;
        esac
    fi

    log_crit "unable to determine libc"
    1>&2
    exit 1
}

# Resolves a given tag (like 'latest') to the actual release tag from GitHub.
real_tag() {
    tag="${1}"
    log_debug "checking GitHub for tag ${tag}"

    release_url="https://githubfast.com/twpayne/chezmoi/releases/${tag}"
    json="$(http_get "${release_url}" "Accept: application/json")"

    if [ -z "${json}" ]; then
        log_err "real_tag error retrieving GitHub release ${tag}"
        return 1
    fi

    # Extracts the tag name from the JSON response.
    real_tag="$(printf '%s\n' "${json}" | tr -s '\n' ' ' | sed 's/.*"tag_name":"//' | sed 's/".*//')"

    if [ -z "${real_tag}" ]; then
        log_err "real_tag error determining real tag of GitHub release ${tag}"
        return 1
    fi

    if [ -z "${real_tag}" ]; then
        return 1
    fi

    log_debug "found tag ${real_tag} for ${tag}"
    printf '%s' "${real_tag}"
}

# Performs an HTTP GET request and returns the body.
http_get() {
    tmpfile="$(mktemp)"
    http_download "${tmpfile}" "${1}" "${2}" || return 1
    body="$(cat "${tmpfile}")"
    rm -f "${tmpfile}"
    printf '%s\n' "${body}"
}

# Downloads a file using curl.
http_download_curl() {
    local_file="${1}"
    source_url="${2}"
    header="${3}"

    if [ -z "${header}" ]; then
        code="$(curl -w '%{http_code}' -fsSL -o "${local_file}" "${source_url}")"
    else
        code="$(curl -w '%{http_code}' -fsSL -H "${header}" -o "${local_file}" "${source_url}")"
    fi

    if [ "${code}" != "200" ]; then
        log_debug "http_download_curl received HTTP status ${code}"
        return 1
    fi

    return 0
}

# Downloads a file using wget.
http_download_wget() {
    local_file="${1}"
    source_url="${2}"
    header="${3}"

    if [ -z "${header}" ]; then
        wget -q -O "${local_file}" "${source_url}" || return 1
    else
        wget -q --header "${header}" -O "${local_file}" "${source_url}" || return 1
    fi
}

# Detects and uses curl or wget to download a file.
http_download() {
    log_debug "http_download ${2}"

    if is_command curl; then
        http_download_curl "${@}" || return 1
        return
    elif is_command wget; then
        http_download_wget "${@}" || return 1
        return
    fi

    log_crit "http_download unable to find wget or curl"
    return 1
}

# Calculates the SHA256 hash of a file.
hash_sha256() {
    target="${1}"

    if is_command sha256sum; then
        hash="$(sha256sum "${target}")" || return 1
        printf '%s' "${hash}" | cut -d ' ' -f 1
    elif is_command shasum; then
        hash="$(shasum -a 256 "${target}" 2>/dev/null)" || return 1
        printf '%s' "${hash}" | cut -d ' ' -f 1
    elif is_command sha256; then
        hash="$(sha256 -q "${target}" 2>/dev/null)" || return 1
        printf '%s' "${hash}" | cut -d ' ' -f 1
    elif is_command openssl; then
        hash="$(openssl dgst -sha256 "${target}")" || return 1
        printf '%s' "${hash}" | cut -d ' ' -f a
    else
        log_crit "hash_sha256 unable to find command to compute SHA256 hash"
        return 1
    fi
}

# Verifies the SHA256 hash of a file against a checksums file.
hash_sha256_verify() {
    target="${1}"
    checksums="${2}"
    basename="${target##*/}"

    want="$(grep "${basename}" "${checksums}" 2>/dev/null | tr '\t' ' ' | cut -d ' ' -f 1)"

    if [ -z "${want}" ]; then
        log_err "hash_sha256_verify unable to find checksum for ${target} in ${checksums}"
        return 1
    fi

    got="$(hash_sha256 "${target}")"

    if [ "${want}" != "${got}" ]; then
        log_err "hash_sha256_verify checksum for ${target} did not verify ${want} vs ${got}"
        return 1
    fi
}

# Extracts a given archive file based on its extension.
untar() {
    tarball="${1}"
    case "${tarball}" in
        *.tar.gz | *.tgz)
            tar -xzf "${tarball}"
            ;;
        *.tar)
            tar -xf "${tarball}"
            ;;
        *.zip)
            unzip -- "${tarball}"
            ;;
        *)
            log_err "untar unknown archive format for ${tarball}"
            return 1
            ;;
    esac
}

# Checks if a command exists in the system's PATH.
is_command() {
    type "${1}" >/dev/null 2>&1
}

# --- Logging Functions ---

# Logs a debug message if LOG_LEVEL is 3 or higher.
log_debug() {
    [ 3 -le "${LOG_LEVEL}" ] || return 0
    printf 'debug %s\n' "${*}" 1>&2
}

# Logs an info message if LOG_LEVEL is 2 or higher.
log_info() {
    [ 2 -le "${LOG_LEVEL}" ] || return 0
    printf 'info %s\n' "${*}" 1>&2
}

# Logs an error message if LOG_LEVEL is 1 or higher.
log_err() {
    [ 1 -le "${LOG_LEVEL}" ] || return 0
    printf 'error %s\n' "${*}" 1>&2
}

# Logs a critical message if LOG_LEVEL is 0 or higher.
log_crit() {
    [ 0 -le "${LOG_LEVEL}" ] || return 0
    printf 'critical %s\n' "${*}" 1>&2
}

# --- Main Execution ---
# The main entry point of the script.
main "${@}"
