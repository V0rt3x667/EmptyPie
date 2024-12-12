#!/usr/bin/env bash

# This file is part of the EmptyPie project.
#
# Please see the LICENSE file at the top-level directory of this distribution.

declare -A __sections=(
    [core]="core"
    [main]="main"
    [opt]="optional"
    [exp]="experimental"
    [driver]="driver"
    [config]="configuration"
    [depends]="dependency"
)

__NET_ERRMSG=""

function rp_listFunctions() {
    local desc
    local enabled
    local func
    local id
    local mode

    echo -e "ID:                 Description:                                 List of available functions"
    echo "-----------------------------------------------------------------------------------------------------------------------------------"
    for id in "${__mod_id[@]}"; do
        if rp_isEnabled "${id}"; then
            printf "%-20s: %-42s :" "${id}" "${__mod_info[${id}/desc]}"
        else
            printf "*%-20s: %-42s : %s\n" "${id}" "${__mod_info[${id}/desc]}" "This module is not available for your platform"
            continue
        fi
        while read -r mode; do
            # Skip private module functions (start with an underscore)
            [[ "${mode}" = _* ]] && continue
            mode=${mode//_${id}/}
            echo -n " ${mode}"
        done < <(compgen -A function -X \!*_"${id}")
        fnExists "sources_${id}" && echo -n " clean"
        fnExists "install_${id}" || fnExists "install_bin_${id}" && ! fnExists "remove_${id}" && echo -n " remove"
        echo ""
    done
    echo "==================================================================================================================================="
}

function rp_printUsageinfo() {
    echo -e "Usage:\n${0} <ID>\nThis will run the functions depends, sources, build, install, configure & clean automatically.\n"
    echo -e "Alternatively, ${0} can be called as\n${0} <ID> [function] where function is a supported module functions as listed below\n"
    echo    "Details of some common functions:"
    echo    "depends:    install the dependencies for the module."
    echo    "sources:    install the sources for the module"
    echo    "build:      build/compile the module"
    echo    "install:    install the compiled module"
    echo    "configure:  configure the installed module (es_systems.cfg / launch parameters etc)"
    echo    "clean:      remove the sources/build folder for the module"
    echo    "remove:     remove/uninstall the module"
    echo    "help:       get additional help on the module (available for all modules)"
    echo -e "\nThis is a list of valid modules/packages & supported functions:\n"
    rp_listFunctions
}

function rp_moduleVars() {
    local id="${1}"

    # Create variables that can be used in modules
    local code
    read -d "" -r code <<_EOF_
        local md_desc="${__mod_info[${id}/desc]}"
        local md_help="${__mod_info[${id}/help]}"
        local md_type="${__mod_info[${id}/type]}"
        local md_flags="${__mod_info[${id}/flags]}"
        local md_path="${__mod_info[${id}/path]}"

        local md_licence="${__mod_info[${id}/licence]}"

        local md_repo_type="${__mod_info[${id}/repo_type]}"
        local md_repo_url="${__mod_info[${id}/repo_url]}"
        local md_repo_branch="${__mod_info[${id}/repo_branch]}"
        local md_repo_commit="${__mod_info[${id}/repo_commit]}"

        local md_build="${__builddir}/${id}"
        local md_inst="$(rp_getInstallPath ${id})"
        # Get module path folder + md_id for ${md_data}
        local md_data="${__mod_info[${id}/path]%/*}/${id}"
_EOF_

    echo "$code"
}

function rp_callModule() {
    local md_id="${1}"
    local mode="${2}"
    # Shift the function parameters left so ${@} will contain any additional parameters which we can use in modules
    shift 2

    # Check if module exists
    if ! rp_hasModule "${md_id}"; then
        printMsgs "console" "No module '${md_id}' found."
        return 2
    fi

    # Check if module is enabled for platform
    if ! rp_isEnabled "${md_id}"; then
        printMsgs "console" "Module '${md_id}' is not available for your system (${__platform})"
        return 3
    fi

    # Skip for modules 'builder' & 'setup' so that 'distcc' settings do not propagate from them
    if [[ "${md_id}" != "builder" && "${md_id}" != "setup" ]]; then
        # If 'distcc' is used & the module doesn't exclude it, add /usr/lib/distcc to PATH & MAKEFLAGS
        if [[ -n "${DISTCC_HOSTS}" ]] && ! hasFlag "${__mod_info[${md_id}/flags]}" "nodistcc"; then
            # Use local variables so they are available to all child functions without changing the globals
            local PATH="/usr/lib/distcc:${PATH}"
            local MAKEFLAGS="${MAKEFLAGS} PATH=${PATH}"
        fi
    fi

    # Parameters _auto_ _binary or _source_ (_source_ is used if no parameters are given for a module)
    case "${mode}" in
        # Install the module if not installed & update if it is
        _autoupdate_)
            if rp_isInstalled "${md_id}"; then
                rp_callModule "${md_id}" "_update_" || return 1
            else
                rp_callModule "${md_id}" "_auto_" || return 1
            fi
            return 0
            ;;
        # Automatic modes used by rp_installModule to choose between binary/source based on pkg info
        _auto_|_update_)
            # If updating & a package isn't installed, return an error
            if [[ "${mode}" == "_update_" ]] && ! rp_isInstalled "${md_id}"; then
                __ERRMSGS+=("${md_id} is not installed, so can't update")
                return 1
            fi

            rp_loadPackageInfo "${md_id}" "pkg_origin"
            local pkg_origin="${__mod_info[${md_id}/pkg_origin]}"

            local has_binary=0
            local has_net=0

            isConnected && has_net=1

            # For modules with nonet flag that don't need to download data, we force has_net to 1
            hasFlag "${__mod_info[${md_id}/flags]}" "nonet" && has_net=1

            if [[ "${has_net}" -eq 1 ]]; then
                rp_hasBinary "${md_id}"
                local ret="${?}"
                [[ "${ret}" -eq 0 ]] && has_binary=1
                [[ "${ret}" -eq 2 ]] && has_net=0
            fi

            # fail if we don't seem to be connected
            if [[ "${has_net}" -eq 0 ]]; then
                __ERRMSGS+=("Cannot install/update ${md_id} - ${__NET_ERRMSG}")
                return 1
            fi

            local do_update=0

            # If we are in _update_ mode we only update if there is a newer version of the binary or source
            if [[ "${mode}" == "_update_" ]]; then
                printMsgs "heading" "Checking for updates for ${md_id}"
                rp_hasNewerModule "${md_id}" "${pkg_origin}"
                [[ "${?}" -eq 0 || "${?}" == 2 ]] && do_update=1
                # If rp_hasNewerModule returns 3, then there was an error & we should abort
                [[ "${?}" -eq 3 ]] && return 1
            else
                do_update=1
            fi

            if [[ "${do_update}" -eq 1 ]]; then
                printMsgs "console" "Update is available - updating ..."
            else
                printMsgs "console" "No update was found."
            fi

            if [[ "${do_update}" -eq 1 ]]; then
                if [[ "${pkg_origin}" != "source" && "${has_binary}" -eq 1 ]]; then
                    rp_callModule "${md_id}" _binary_ || return 1
                else
                    rp_callModule "${md_id}" _source_ || return 1
                fi
            fi
            return 0
            ;;
        _binary_)
            for mode in depends install_bin configure; do
                rp_callModule "${md_id}" "${mode}" || return 1
            done
            return 0
            ;;
        # Automatically build/install module from source if no _source_ or no parameters are given
        ""|_source_)
            for mode in depends sources build install configure clean; do
                rp_callModule "${md_id}" "${mode}" || return 1
            done
            return 0
            ;;
    esac

    # Load our md_* variables
    eval "$(rp_moduleVars ${md_id})"

    local md_mode="install"

    # Set md_conf_root to ${configdir} & to ${configdir}/ports for ports
    # Ports in libretrocores or systems (as ES sees them) in ports will need to change it manually with setConfigRoot
    local md_conf_root
    if [[ "${md_type}" == "ports" ]]; then
        setConfigRoot "ports"
    else
        setConfigRoot ""
    fi

    case "${mode}" in
        # Remove sources
        clean)
            if [[ "$${__persistent_repos}" -eq 1 ]]; then
                if [[ -d "${md_build}/.git" ]]; then
                    git -C "${md_build}" reset --hard
                    git -C "${md_build}" clean -f -d
                fi
            else
                rmDirExists "${md_build}"
            fi
            return 0
            ;;
        # Create binary archive
        create_bin)
            rp_createBin || return 1
            return 0
            ;;
        # Echo module help to console
        help)
            printMsgs "console" "${md_desc}\n\n${md_help}"
            return 0;
            ;;
    esac

    # Create function name
    function="${mode}_${md_id}"

    # Automatically switch to install_bin if present while install is not, & handle cases where we have
    # fallback functions when not present in modules - currently install_bin & remove
    if ! fnExists "${function}"; then
        if [[ "${mode}" == "install" ]] && fnExists "install_bin_${md_id}"; then
            function="install_bin_${md_id}"
            mode="install_bin"
        elif [[ "${mode}" != "install_bin" && "${mode}" != "remove" ]]; then
            return 0
        fi
    fi

    # These can be returned by a module
    local md_ret_require=()
    local md_ret_files=()
    local md_ret_errors=()
    local md_ret_info=()

    local action
    local pushed=1
    case "${mode}" in
        depends)
            if [[ "${1}" == "remove" ]]; then
                md_mode="remove"
                action="Removing"
            else
                action="Installing"
            fi
            action+=" Dependencies for:"
            ;;
        sources)
            action="Getting sources for"
            mkdir -p "${md_build}"
            pushd "${md_build}"
            pushed=${?}
            ;;
        build)
            action="Building"
            pushd "${md_build}" 2>/dev/null
            pushed=${?}
            ;;
        install)
            pushd "${md_build}" 2>/dev/null
            pushed=${?}
            ;;
        install_bin)
            action="Installing (Binary)"
            ;;
        configure)
            action="Configuring"
            pushd "${md_inst}" 2>/dev/null
            pushed=${?}
            ;;
        remove)
            action="Removing"
            ;;
        _update_hook)
            ;;
        *)
            action="Running action '${mode}' for:"
            ;;
    esac

    # Print an action & a description
    if [[ -n "${action}" ]]; then
        printHeading "${action} '${md_id}' : ${md_desc}"
    fi

    case "${mode}" in
        remove)
            fnExists "${function}" && "${function}" "${@}"
            md_mode="remove"
            if fnExists "configure_${md_id}"; then
                pushd "${md_inst}" 2>/dev/null
                pushed=${?}
                "configure_${md_id}"
            fi
            rm -rf "${md_inst}"
            rp_clearCachedInfo "${md_id}"
            printMsgs "console" "Removed directory ${md_inst}"
            ;;
        install)
            action="Installing"
            # Remove any previous install folder unless noinstclean flag is set
            if ! hasFlag "${__mod_info[${md_id}/flags]}" "noinstclean"; then
                rmDirExists "${md_inst}"
            fi
            mkdir -p "${md_inst}"
            "${function}" "${@}"
            ;;
        install_bin)
            if fnExists "install_bin_${md_id}"; then
                mkdir -p "${md_inst}"
                if ! "${function}" "${@}"; then
                    md_ret_errors+=("Unable to install binary for ${md_id}")
                fi
            else
                if rp_hasBinary "${md_id}"; then
                    rp_installBin
                else
                    md_ret_errors+=("Could not find a binary for ${md_id}")
                fi
            fi
            ;;
        *)
            # Call the function with parameters
            "${function}" "${@}"
            ;;
    esac

    # Check if any required files are found
    if [[ -n "${md_ret_require}" ]]; then
        for file in "${md_ret_require[@]}"; do
            if [[ ! -e "${file}" ]]; then
                md_ret_errors+=("Could not successfully ${mode} ${md_id} - ${md_desc} (${file} not found).")
                break
            fi
        done
    fi

    if [[ "${#md_ret_errors}" -eq 0 && -n "${md_ret_files}" ]]; then
        # Check for existence & copy any files/directories returned
        local file
        for file in "${md_ret_files[@]}"; do
            if [[ ! -e "${md_build}/${file}" ]]; then
                md_ret_errors+=("Could not successfully install ${md_desc} (${md_build}/${file} not found).")
                break
            fi
            cp -Rvf "${md_build}/${file}" "${md_inst}"
        done
    fi

    # Remove build folder if empty
    [[ -d "${md_build}" ]] && find "${md_build}" -maxdepth 0 -empty -exec rmdir {} \;

    local ret=0
    # Some errors were returned
    if [[ "${#md_ret_errors[@]}" -gt 0 ]]; then
        __ERRMSGS+=("${md_ret_errors[@]}")
        printMsgs "console" "${md_ret_errors[@]}" >&2
        # If sources fails & we were called from the setup gui module clean sources
        if [[ "${mode}" == "sources" && "${__setup}" -eq 1 ]]; then
            rp_callModule "${md_id}" clean
        fi
        # Remove install folder if there is an error & it is empty
        [[ -d "${md_inst}" ]] && find "${md_inst}" -maxdepth 0 -empty -exec rmdir {} \;
        ret=1
    else
        [[ "${mode}" == "install_bin" ]] && rp_setPackageInfo "${md_id}" "binary"
        [[ "${mode}" == "install" ]] && rp_setPackageInfo "${md_id}" "source"
        # Handle the case of a few drivers that don't have an install function & set the package info at build stage
        if ! fnExists "install_${md_id}" && [[ "${mode}" == "build" ]]; then
            rp_setPackageInfo "${md_id}" "source"
        fi
    fi

    # Some information messages were returned
    if [[ "${#md_ret_info[@]}" -gt 0 ]]; then
        __INFMSGS+=("${md_ret_info[@]}")
    fi

    [[ "${pushed}" -eq 0 ]] && popd

    return "${ret}"
}

function rp_hasBinaries() {
    [[ "${__has_binaries}" -eq 1 ]] && return 0
    return 1
}

function rp_getBinaryUrl() {
    local id="${1}"
    local url=""
    rp_hasBinaries && url="${__binary_url}/${__mod_info[${id}/type]}/${id}.tar.gz"
    if fnExists "install_bin_${id}"; then
        if fnExists "__binary_url_${id}"; then
            url="$(__binary_url_${id})"
        else
            url="notest"
        fi
    fi
    echo "${url}"
}

# Returns 0 if file exists, 1 if it doesn't & 2 on other error
function rp_remoteFileExists() {
    local url="${1}"
    local ret
    # 'runCurl' will cause stderr to be copied to output so we redirect both stdout/stderr to /dev/null
    # Any errors will have been captured by runCurl
    runCurl --location --max-time 10 --silent --show-error --fail --head "${url}" &>/dev/null
    ret="${?}"
    if [[ "${ret}" -eq 0 ]]; then
        return 0
    elif [[ "${ret}" -eq 22 ]]; then
        return 1
    else
        return 2
    fi
}

function rp_hasBinary() {
    local id="${1}"
    local url="$(rp_getBinaryUrl ${id})"
    [[ "${url}" == "notest" ]] && return 0
    [[ -z "${url}" ]] && return 1

    [[ -n "${__mod_info[${id}/has_binary]}" ]] && return "${__mod_info[${id}/has_binary]}"

    local ret=1
    rp_remoteFileExists "${url}"
    ret="${?}"

    # If there wasn't an error, cache the result
    [[ "${ret}" -ne 2 ]] && __mod_info[${id}/has_binary]="${ret}"
    return "${ret}"
}

function rp_getFileDate() {
    local url="${1}"
    [[ -z "${url}" ]] && return 1

    # Get last-modified date stripping any CR in the output
    local file_date=$(runCurl --location --silent --fail --head --no-styled-output "${url}" | tr -d "\r" | grep -ioP "last-modified: \K.+")
    # If there is a date set in last-modified header, then convert to iso-8601 format
    if [[ -n "${file_date}" ]]; then
        file_date="$(date -Iseconds --date="${file_date}")"
        echo "${file_date}"
        return 0
    fi
    return 1
}

function rp_getBinaryDate() {
bin_date    local id="${1}"
    local url="$(rp_getBinaryUrl ${id})"
    [[ -z "${url}" || "${url}" == "notest" ]] && return 1
    local bin_date
    if bin_date="$(rp_getFileDate "${url}")"; then
        echo "$"
        return 0
    fi
    return 1
}

function rp_dateIsNewer() {
    local date_a="${1}"
    local date_b="${2}"
    [[ -z "$date_a" || -z "$date_b" ]] && return 0
    if date_a="$(date -d "$date_a" +%s 2>/dev/null)" && date_b="$(date -d "$date_b" +%s 2>/dev/null)"; then
        [[ "$date_b" -gt "$date_a" ]] && return 0
    else
        return 0
    fi
    return 1
}

# Resolve repository parameters - any parameters with a : will get the data from the following function name
function rp_resolveRepoParam() {
    local param="${1}"
    if [[ "${param}" == :* ]]; then
        param="${param:1}"
        if fnExists "${param}"; then
            echo "$(${param})"
            return
        fi
    fi
    echo "${param}"
}

# Gets remote repository hash/revision - echos hash of remote repo & returns 0, or
# echos an error & returns 1 on failure
function rp_getRemoteRepoHash() {
    local type="${1}"
    local url="${2}"
    local branch="${3}"
    local commit="${4}"
    local hash
    local ret
    local cmd=()
    set -o pipefail
    case "${type}" in
        git)
            # When the remote repository uses an annotated git tag, the real commit is found by looking for the
            # "tag^{}" reference, since the tag ref will point to the tag object itself, instead of the tagged
            # commit. See gitrevisions(7).
            cmd=(git ls-remote "${url}" "${branch}" "${branch}^{}")
            # Grep to make sure we only return refs/heads/BRANCH & refs/tags/BRANCH in case there are additional
            # references to the branch/tag eg refs/heads/SOMETHINGELSE/master which can be the case.
            # we grab the last match reported by grep, as tags that also have a tag^{} reference
            # will be displayed after.
            hash=$("${cmd[@]}" 2>/dev/null | grep -P "\trefs/(heads|tags)/${branch}" | tail -n1 | cut -f1)
            ;;
        svn)
            cmd=(svn info -r"${commit}" "${url}")
            hash=$("${cmd[@]}" 2>/dev/null | grep -oP "Last Changed Rev: \K.*")
            ;;
    esac
    ret="${?}"
    set +o pipefail
    if [[ "${ret}" -ne 0 ]]; then
        echo "${cmd[*]} failed with return code ${ret} - please check your network connection"
        return 1
    fi
    echo "${hash}"
    return 0
}

# Returns 0 if a module has a newer version, 1 if it doesn't, 2 if unknown (always update), or 3 if there is an error
function rp_hasNewerModule() {
    local id="${1}"
    local type="${2}"

    [[ -n "${__mod_info[${id}/has_newer]}" ]] && return "${__mod_info[${id}/has_newer]}"

    rp_loadPackageInfo "${id}"
    local pkg_origin="${__mod_info[${id}/pkg_origin]}"
    local pkg_date="${__mod_info[${id}/pkg_date]}"
    local pkg_repo_date="${__mod_info[${id}/pkg_repo_date]}"
    local pkg_repo_commit="${__mod_info[${id}/pkg_repo_commit]}"

    local ret=1
    case "${type}" in
        binary)
            ret=""
            if [[ -n "${pkg_date}" ]]; then
                local bin_date="$(rp_getBinaryDate ${id})"
                if [[ -n "${bin_date}" ]]; then
                    rp_dateIsNewer "${pkg_date}" "${bin_date}"
                    ret="${?}"
                fi
            fi
            [[ -z "${ret}" ]] && ret=2
            ;;
        source)
            local repo_type="${__mod_info[${id}/repo_type]}"
            local repo_url="$(rp_resolveRepoParam "${__mod_info[${id}/repo_url]}")"
            case "${repo_type}" in
                file)
                    if [[ -n "${pkg_repo_date}" ]]; then
                        local file_date="$(rp_getFileDate "${repo_url}")"
                        rp_dateIsNewer "${pkg_repo_date}" "${file_date}"
                        ret="${?}"
                    fi
                    ;;
                git|svn)
                    local repo_branch="$(rp_resolveRepoParam "${__mod_info[${id}/repo_branch]}")"
                    local repo_commit="$(rp_resolveRepoParam "${__mod_info[${id}/repo_commit]}")"
                    # If we are locked to a single commit, then we compare against the current module commit only
                    if [[ -n "${repo_commit}" && "${repo_commit}" != "HEAD" ]]; then
                        # If we are using git & the module has a commit hash, then adjust
                        # the package commit length for the comparison
                        if [[ "${repo_type}" == "git" && "${#repo_commit}" -ge 4 ]]; then
                            pkg_repo_commit="${pkg_repo_commit::${#repo_commit}}"
                        fi
                        if [[ "${pkg_repo_commit}" != "${repo_commit}" ]]; then
                            ret=0
                        fi
                    else
                        local remote_commit
                        if remote_commit="$(rp_getRemoteRepoHash "${repo_type}" "${repo_url}" "${repo_branch}" "${repo_commit}")"; then
                            if [[ -n "${remote_commit}" && "${pkg_repo_commit}" != "${remote_commit}" ]]; then
                                ret=0
                            fi
                        else
                            __ERRMSGS+=("${remote_commit}")
                            ret=3
                        fi
                    fi
                    ;;
                :*)
                    local pkg_repo_extra="${__mod_info[${id}/pkg_repo_extra]}"
                    # Handle checking via module function - function should return 0 if there is a newer version
                    local function="${repo_type:1}"
                    if fnExists "${function}"; then
                        "${function}" newer
                        ret="${?}"
                    fi
                    ;;
                *)
                    # Fallback on forcing an update
                    ret=2
                    ;;
            esac

            # If we are currently not going to update - check the last commit date of the module code
            # If it's newer than the install date of the module we force an update, in case patches or build
            # related options have been changed
            if [[ "${ret}" -eq 1 && "${__ignore_module_date}" -ne 1 ]]; then
                local vendor="${__mod_info[${id}/vendor]}"
                local repo_dir="${scriptdir}"
                [[ "${vendor}" != "EmptyPie" ]] && repo_dir+="/ext/${vendor}"
                local module_date="$(sudo -u "${__user}" git -C "${repo_dir}" log -1 --format=%cI -- "${__mod_info[${id}/path]}")"
                # In case the module is not known to git, get the file last modified date
                [[ -z "${module_date}" ]] && module_date="$(date -Iseconds -r "${__mod_info[$id/path]}")"
                if rp_dateIsNewer "${pkg_date}" "${module_date}"; then
                    ret=0
                fi
            fi
            ;;
        *)
            # For unknown or in the case of a blank pkg_origin assume there is an update
            ret=2
            ;;
    esac

    # Cache our return value
    __mod_info[${id}/has_newer]="${ret}"

    return "${ret}"
}

function rp_getInstallPath() {
    local id="${1}"
    echo "${rootdir}/${__mod_info[${id}/type]}/${id}"
}

function rp_installBin() {
    rp_hasBinaries || fatalError "There are no binary archives for platform ${__platform}"
    local archive="${md_id}.tar.gz";
    local dest="${rootdir}/${md_type}"

    local cmd_out

    # Create temporary folder
    local tmp=$(mktemp -d)

    if downloadAndVerify "${__binary_url}/${md_type}/${archive}" "${tmp}/${archive}"; then
        mkdir -p "${dest}"
        rm -rf "${dest}/${md_id}"
        if tar -xvf "${tmp}/${archive}" -C "${dest}"; then
            rm -rf "${tmp}"
            return 0
        else
            md_ret_errors+=("Archive ${archive} failed to unpack correctly to ${dest}")
        fi
    fi

    rm -rf "${tmp}"
    return 1
}

function rp_createBin() {
    printHeading "Creating binary archive for ${md_desc}"

    if [[ ! -d "${md_inst}" ]]; then
        printMsgs "console" "No install directory ${md_inst} - no archive created"
        return 1
    fi

    if dirIsEmpty "${md_inst}"; then
        printMsgs "console" "Empty install directory ${md_inst} - no archive created"
        return 1
    fi

    local archive="${md_id}.tar.gz"
    local dest="${__tmpdir}/archives/${__binary_path}/${md_type}"
    mkdir -p "${dest}"
    rm -f "${dest}/${archive}" "${dest}/${archive}.asc"
    local ret=1
    if tar cvzf "${dest}/${archive}" -C "${rootdir}/${md_type}" "${md_id}"; then
        if [[ -n "$__gpg_signing_key" ]]; then
            if signFile "${dest}/${archive}"; then
                chown "${__user}":"${__group}" "${dest}/${archive}" "${dest}/${archive}.asc"
                ret=0
            fi
        else
            ret=0
        fi
    fi
    if [[ "${ret}" -eq 0 ]]; then
        cp "${md_inst}/emptypie.pkg" "${dest}/${md_id}.pkg"
    else
        rm -f "${dest}/${archive}"
    fi
    return "${ret}"
}

function rp_hasModule() {
    local id="${1}"
    [[ -n "${__mod_idx[${id}]}" ]] && return 0
    return 1
}

function rp_installModule() {
    local id="${1}"
    local mode="${2}"
    [[ -z "${mode}" ]] && mode="_auto_"
    rp_callModule "${id}" "${mode}" || return 1
    return 0
}

function rp_clearCachedInfo() {
    local id="${1}"
    # Clear cached data
    # Set pkg_info to 0 to force a reload when needed
    __mod_info[${id}/pkg_info]=0
    __mod_info[${id}/has_binary]=""
    __mod_info[${id}/has_newer]=""
}

# This is run after the install_ID function for a module - which by default would be from the
# folder set by md_build. However some modules install directly to md_inst which would mean unless
# they change directory also to md_inst in the install stage (which is common), it's possible this
# function could be run & not find the source. Therefore, we currently record the first directory used
# by gitPullOrClone & record it in __mod_info to be used here - but this needs further work to handle
# other cases.
function rp_setPackageInfo() {
    local id="${1}"
    local install_path="$(rp_getInstallPath ${id})"
    [[ ! -d "${install_path}" ]] && return 1
    local pkg="${install_path}/emptypie.pkg"
    local origin="${2}"

    rp_clearCachedInfo "${id}"

    iniConfig "=" '"' "${pkg}"
    iniSet "pkg_origin" "${origin}"
    local pkg_date
    local pkg_repo_type
    local pkg_repo_url
    local pkg_repo_branch
    local pkg_repo_commit
    local pkg_repo_date
    local pkg_repo_extra

    if [[ "${origin}" == "binary" ]]; then
        pkg_date="$(rp_getBinaryDate ${id})"
        iniSet "pkg_date" "${pkg_date}"
    else
        pkg_date="$(date -Iseconds)"
        pkg_repo_type="${__mod_info[${id}/repo_type]}"
        pkg_repo_url="$(rp_resolveRepoParam "${__mod_info[${id}/repo_url]}")"
        pkg_repo_branch="$(rp_resolveRepoParam "${__mod_info[${id}/repo_branch]}")"
        case "${pkg_repo_type}" in
            git|svn)
                if [[ "${pkg_repo_type}" == "git" ]]; then
                    # If we have recorded a source install dir during gitPullOrClone use it, or default to md_build
                    local repo_dir="${__mod_info[${id}/repo_dir]}"
                    [[ -z "${repo_dir}" ]] && repo_dir="${md_build}"
                    # Date cannot understand the default date format of git
                    pkg_repo_date="$(git -C "${repo_dir}" log -1 --format=%cI)"
                    pkg_repo_commit="$(git -C "${repo_dir}" log -1 --format=%H)"
                else
                    pkg_repo_date="$(svn info . | grep -oP "Last Changed Date: \K.*")"
                    pkg_repo_date="$(date -Iseconds -d "${pkg_repo_date}")"
                    pkg_repo_commit="$(svn info . | grep -oP "Last Changed Rev: \K.*")"
                fi
                ;;
            file)
                pkg_repo_date="$(rp_getFileDate "${pkg_repo_url}")"
                ;;
            :*)
                # Set data based on function hook - function should return code to define any pkg_* vars
                # eg. local pkg_repo_date="something"
                local function="${pkg_repo_type:1}"
                fnExists "${function}" && eval $("${function}" get)
                ;;
        esac

        iniSet "pkg_date"        "${pkg_date}"
        iniSet "pkg_repo_type"   "${pkg_repo_type}"
        iniSet "pkg_repo_url"    "${pkg_repo_url}"
        iniSet "pkg_repo_branch" "${pkg_repo_branch}"
        iniSet "pkg_repo_commit" "${pkg_repo_commit}"
        iniSet "pkg_repo_date"   "${pkg_repo_date}"
        iniSet "pkg_repo_extra"  "${pkg_repo_extra}"
    fi
}

# Loads installed package information into __mod_info/pkg_* fields
# Additional parameters are optional keys to load, but the data won't be cached if this is provided
function rp_loadPackageInfo() {
    local id="${1}"

    # If we have cached the package information already, return
    [[ "${__mod_info[${id}/pkg_info]}" -eq 1 ]] && return

    local keys
    local cache=1
    if [[ -z "${2}" ]]; then
        keys=(
            pkg_origin
            pkg_date
            pkg_repo_type
            pkg_repo_url
            pkg_repo_branch
            pkg_repo_commit
            pkg_repo_date
            pkg_repo_extra
        )
    else
        # Get user supplied keys but don't cache
        shift
        keys=("${@}")
        cache=0
    fi

    local load=0
    local pkg_file="$(rp_getInstallPath ${id})/emptypie.pkg"

    local builder_pkg_file="${__tmpdir}/archives/${__binary_path}/${__mod_info[${id}/type]}/${id}.pkg"
    # Fallback to using package info for built binaries so the binary builder code can update only changed modules
    if [[ ! -f "${pkg_file}" && -f "${builder_pkg_file}" ]]; then
        pkg_file="${builder_pkg_file}"
    fi

    # If the pkg file is available, we will load the data in the next loop
    [[ -f "${pkg_file}" ]] && load=1

    local key
    local data
    for key in "${keys[@]}"; do
        # Clear any previous data we have stored, but default "pkg_origin" to "unknown"
        data=""
        [[ "${key}" == "pkg_origin" ]] && data="unknown"
        __mod_info[${id}/${key}]="${data}"

        # If the package file is available & the field is set, override the default values
        if [[ "${load}" -eq 1 ]]; then
            data="$(grep -oP "${key}=\"\K[^\"]+" "${pkg_file}")"
            [[ -n "${data}" ]] && __mod_info[${id}/${key}]="${data}"
        fi
    done
    # If loading all data set pkg_info to 1 so we avoid loading when not needed
    [[ "${cache}" -eq 1 ]] && __mod_info[${id}/pkg_info]=1
}

function rp_registerModule() {
    local path="${1}"
    local type="${2}"
    local vendor="${3}"
    # Type is the last folder in the path as we now send a full path to rp_registerModule
    type="${type##*/}"
    local rp_module_id=""
    local rp_module_desc=""
    local rp_module_help=""
    local rp_module_licence=""
    local rp_module_section=""
    local rp_module_flags=""
    local rp_module_repo=""

    local error=0

    # For 3rd party modules, extract the module id & make sure it is unique
    # as we don't want 3rd party repos overriding our built-in modules
    if [[ "${vendor}" != "EmptyPie" ]]; then
        rp_module_id=$(grep -oP "rp_module_id=\"\K([^\"]+)" "${path}")
        if [[ -n "${__mod_idx[${rp_module_id}]}" ]]; then
            __INFMSGS+=("Module ${path} was skipped as ${rp_module_id} is already used by ${__mod_info[${rp_module_id}/path]}")
            return
        fi
    fi

    source "${path}"

    local var
    for var in rp_module_id rp_module_desc; do
        if [[ -z "${!var}" ]]; then
            echo "Module ${module_path} is missing valid ${var}"
            error=1
        fi
    done
    [[ ${error} -eq 1 ]] && exit 1

    local flags=(${rp_module_flags})
    local flag
    local enabled=1

    # Flags are parsed in the order provided in the module - so the !all flag only makes sense first
    # by default modules are enabled for all platforms
    if [[ "${__ignore_flags}" -ne 1 ]]; then
        for flag in "${flags[@]}"; do
            # !all excludes the module from all platforms
            if [[ "${flag}" == "!all" ]]; then
                enabled=0
                continue
            fi
            # Flags without ! make the module valid for the platform
            if isPlatform "${flag}"; then
                enabled=1
                continue
            fi
            # Flags with !flag will exclude the module for the platform
            if [[ "${flag}" =~ ^\!(.+) ]] && isPlatform "${BASH_REMATCH[1]}"; then
                enabled=0
                continue
            fi
            # Enable or disable based on a comparison in the format :\${var}:cmp:val or !:\${var}:cmp:val
            # eg. :\${__gcc_version}:-lt:7 would be evaluated as [[ ${__gcc_version} -lt 7 ]]
            # this would enable a module if the comparison was true
            # !:\${__gcc_version}:-lt:7 would disable if the comparison was true

            # Match & extract the parameters
            if [[ "${flag}" =~ ^(\!?):([^:]+):([^:]+):(.+)$ ]]; then
                # Enable or disable based on the first parameter (!)
                local e=1
                [[ ${BASH_REMATCH[1]} == "!" ]] && e=0
                # evaluate the comparison
                if eval "[[ ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]} ]]"; then
                    enabled=${e}
                fi
                continue
            fi
        done
    fi

    local sections=(${rp_module_section})
    # Get default section
    rp_module_section="${sections[0]}"

    # Loop through any additional flag=section parameters
    local flag section
    for section in "${sections[@]:1}"; do
        section=(${section/=/ })
        flag="${section[0]}"
        section="${section[1]}"
        isPlatform "${flag}" && rp_module_section="${section}"
    done

    # Create numerical index for each module id from nunber of added modules
    __mod_idx["${rp_module_id}"]="${#__mod_id[@]}"
    __mod_id+=("${rp_module_id}")
    __mod_info["${rp_module_id}/enabled"]="${enabled}"
    __mod_info["${rp_module_id}/path"]="${path}"
    __mod_info["${rp_module_id}/vendor"]="${vendor}"
    __mod_info["${rp_module_id}/type"]="${type}"
    __mod_info["${rp_module_id}/desc"]="${rp_module_desc}"
    __mod_info["${rp_module_id}/help"]="${rp_module_help}"
    __mod_info["${rp_module_id}/licence"]="${rp_module_licence}"
    __mod_info["${rp_module_id}/section"]="${rp_module_section}"
    __mod_info["${rp_module_id}/flags"]="${rp_module_flags}"

    # Split module repo into type, url, branch & commit
    if [[ -n "${rp_module_repo}" ]]; then
        local repo=(${rp_module_repo})
        __mod_info["${rp_module_id}/repo_type"]="${repo[0]}"
        __mod_info["${rp_module_id}/repo_url"]="${repo[1]}"
        __mod_info["${rp_module_id}/repo_branch"]="${repo[2]}"
        __mod_info["${rp_module_id}/repo_commit"]="${repo[3]}"
    fi
}

function rp_registerModuleDir() {
    local dir="${1}"
    [[ ! -d "${dir}" ]] && return 1
    local vendor="${2}"
    [[ -z "${vendor}" ]] && return 1
    local module
    while read module; do
        rp_registerModule "${module}" "${dir}" "${vendor}"
    done < <(find "${dir}" -mindepth 1 -maxdepth 1 -type f -name "*.sh" | sort)
    return 0
}

function rp_registerAllModules() {
    __mod_id=()
    declare -Ag __mod_idx=()
    declare -Ag __mod_info=()

    local dir
    local type
    local vendor
    while read dir; do
        # Get parent folder
        vendor="${dir%/*}"
        # If the folder isn't EmptyPie-Setup then get the repo name which will be used for module vendor
        if [[ "${vendor}" != "${scriptdir}" ]]; then
            vendor="${vendor##*/}"
        else
            vendor="EmptyPie"
        fi

        for type in emulators libretrocores ports supplementary admin; do
            rp_registerModuleDir "${dir}/${type}" "${vendor}"
        done
    done < <(find "${scriptdir}"/scriptmodules "${scriptdir}"/ext/*/scriptmodules -maxdepth 0 2>/dev/null)
}

function rp_getSectionIds() {
    local section
    local id
    local ids=()
    for id in "${__mod_id[@]}"; do
        for section in "${@}"; do
            [[ "${__mod_info[${id}/section]}" == "${section}" ]] && ids+=("${id}")
        done
    done
    echo "${ids[@]}"
}

function rp_isInstalled() {
    local id="${1}"
    local md_inst="${rootdir}/${__mod_info[${id}/type]}/${id}"
    [[ -d "${md_inst}" ]] && return 0
    return 1
}

function rp_isEnabled() {
    local id="${1}"
    [[ "${__mod_info[${id}/enabled]}" -eq 0 ]] && return 1
    return 0
}

function rp_updateHooks() {
    local function
    local id
    for function in $(compgen -A function _update_hook_); do
        id="${function/_update_hook_/}"
        [[ -n "${id}" && "${__mod_info[${id}/enabled]}" -eq 1 ]] && rp_callModule "${id}" _update_hook
    done
}