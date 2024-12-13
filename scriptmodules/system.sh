#!/usr/bin/env bash

# This file is part of the EmptyPie project.
#
# Please see the LICENSE file at the top-level directory of this distribution.
 
function setup_env() {
    __ERRMSGS=()
    __INFMSGS=()

    test_chroot

    get_platform
    get_os_version

    get_emptypie_depends

    conf_memory_vars
    conf_binary_vars
    conf_build_vars

    if [[ -z "${__nodialog}" ]]; then
        __nodialog=0
    fi
}

function test_chroot() {
    # Detect: 'chroot'
    if [[ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]]; then
        [[ -z "${QEMU_CPU}" && -n "${__qemu_cpu}" ]] && export QEMU_CPU=${__qemu_cpu}
        __chroot=1
    fi
}

function conf_memory_vars() {
    __memory_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    __memory_total=$(( __memory_total_kb / 1024 ))
    if grep -q "^MemAvailable:" "/proc/meminfo"; then
        __memory_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    else
        local mem_free
        local mem_cached
        local mem_buffers
        mem_free=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
        mem_cached=$(awk '/^Cached:/{print $2}' /proc/meminfo)
        mem_buffers=$(awk '/^Buffers:/{print $2}' /proc/meminfo)
        __memory_avail_kb=$((mem_free + mem_cached + mem_buffers))
    fi
    __memory_avail=$(( __memory_avail_kb / 1024 ))
}

function conf_binary_vars() {
    [[ -z "${__has_binaries}" ]] && __has_binaries=0

    # Set: Binary download URLs
    #__binary_host="files.retropie.org.uk"
    #__binary_base_url="https://${__binary_host}/binaries"

    # Code might be used in future
    # __binary_path="${__os_codename}/${__platform}"
    # isPlatform "kms" && __binary_path+="/kms"
    # __binary_url="${__binary_base_url}/${__binary_path}"

    __archive_url="https://files.retropie.org.uk/archives"
    __empie_url="https://github.com/v0rt3x667/emptypie-resources/raw"

    # GPG Key Used By EmptyPie
    #__gpg_retropie_key="retropieproject@gmail.com"

    # If "__gpg_signing_key" Not Set Use "__gpg_retropie_key"
    #[[ ! -v __gpg_signing_key ]] && __gpg_signing_key="${__gpg_retropie_key}"

    # Install: RetroPie Public Key
    #if ! gpg --list-keys "${__gpg_retropie_key}" &>/dev/null; then
    #    gpg --keyserver "hkp://keyserver.ubuntu.com:80" --recv-keys DC9D77FF8208FFC51D8F50CCF1B030906A3B0D31
    #fi
}

function conf_build_vars() {
    __gcc_version=$(gcc -dumpversion)
    # Get: GCC major version
    __gcc_version="${__gcc_version%%.*}"

    # Calculate build concurrency
    __jobs=1
    local unit=512
    isPlatform "64bit" && unit=$((unit + 256))
    if [[ "$(nproc)" -gt 1 ]]; then
        local nproc
        nproc="$(nproc)"
        # One thread per unit MB of RAM
        local max_jobs=$((__memory_avail / unit))
        if [[ "${max_jobs}" -gt 0 ]]; then
            if [[ "${max_jobs}" -lt "${nproc}" ]]; then
                __jobs="${max_jobs}"
            else
                __jobs="${nproc}"
            fi
        fi
    fi
    __default_makeflags="-j${__jobs}"

    # Set: Default GCC optimisation level
    if [[ -z "${__opt_flags}" ]]; then
        __opt_flags="${__default_opt_flags}"
    fi

    # Set: Default CPU flags
    [[ -z "${__cpu_flags}" ]] && __cpu_flags="${__default_cpu_flags}"

    # Set: If '__default_cxxflags' is empty use '__default_cflags'
    [[ -z "${__default_cxxflags}" ]] && __default_cxxflags="${__default_cflags}"

    # Add: CPU & optimisation flags
    __default_cflags+=" ${__cpu_flags} ${__opt_flags}"
    __default_cxxflags+=" ${__cpu_flags} ${__opt_flags}"
    __default_asflags+=" ${__cpu_flags}"

    # Set: Compiler flags
    [[ -z "${__cflags}" ]] && __cflags="${__default_cflags}"
    [[ -z "${__cxxflags}" ]] && __cxxflags="${__default_cxxflags}"
    [[ -z "${__asflags}" ]] && __asflags="${__default_asflags}"
    [[ -z "${__makeflags}" ]] && __makeflags="${__default_makeflags}"

    # Export: Compiler flags
    export CFLAGS="${__cflags}"
    export CXXFLAGS="${__cxxflags}"
    export ASFLAGS="${__asflags}"
    export MAKEFLAGS="${__makeflags}"

    # Set: If '__use_ccache' is set add 'ccache' to PATH & MAKEFLAGS
    if [[ "${__use_ccache}" -eq 1 ]]; then
        PATH="/usr/lib/ccache:${PATH}"
        MAKEFLAGS+=" PATH=${PATH}"
    fi
}

function get_os_version() {
    # Get: OS distributor ID, description, release & codename
    local os
    mapfile -t os < <(lsb_release -idrc | cut -f2)
    __os_id="${os[0]}"
    __os_desc="${os[1]}"
    __os_release="${os[2]}"
    __os_codename="${os[3]}"

    local error=""
    case "${__os_id}" in
        VoidLinux)
            __os_void_ver="${__os_release}"
            __platform_flags+=(void)

            # Code might be used in future
            # if isPlatform "rpi" && isPlatform "32bit"; then
                # Set: __has_binaries if not already set
                # [[ -z "${__has_binaries}" ]] && __has_binaries=1
            # fi
            ;;
        *)
            error="Unsupported OS: This script is for Void Linux!"
            ;;
    esac

    [[ -n "${error}" ]] && fatalError "${error}\n\n$(lsb_release -idrc)"

    # Configure Raspberry Pi graphics stack
    isPlatform "rpi" && get_rpi_video
}

function get_emptypie_depends() {
    local depends=(
        'base-devel'
        'curl'
        'dialog'
        'dpkg'
        'git'
        'mesa'
        'perl-rename'
        'python3-pyudev'
        'unzip'
        'xmlstarlet'
)
    [[ -n "${DISTCC_HOSTS}" ]] && depends+=('distcc')

    [[ "${__use_ccache}" -eq 1 ]] && depends+=('ccache')

    if ! getDepends "${depends[@]}"; then
        fatalError "Unable to install packages required by: ${0} - ${md_ret_errors[*]}"
    fi
}

function get_rpi_video() {
    if [[ -z "${__has_kms}" ]]; then
        if [[ "${__chroot}" -eq 1 ]]; then
            # Force KMS when running in a chroot
            __has_kms=1
        else
            # Detect KMS driver via platform driver setup
            [[ -d "/sys/module/vc4" ]] && __has_kms=1
        fi
    fi

    if [[ "${__has_kms}" -eq 1 ]]; then
        __platform_flags+=('kms' 'mesa')
    fi
}

function get_rpi_model() {
    # Calculated Based On Information From: "https://github.com/AndrewFromMelbourne/raspberry_pi_revision"
    # See Also https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-revision-codes
    local rev="0x$(sed -n '/^Revision/s/^.*: \(.*\)/\1/p' < /proc/cpuinfo)"
    # If Bit 23 Is Set Get The CPU From Bits 12-15
    local cpu=$(((rev >> 12) & 15))
        case ${cpu} in
            1)
                __platform="rpi2"
                ;;
            2)
                __platform="rpi3"
                ;;
            3)
                __platform="rpi4"
                ;;
            4)
                __platform="rpi5"
                ;;
        esac
}

function get_platform() {
    local architecture
    architecture="$(uname --machine)"
    if [[ -z "$__platform" ]]; then
        case "$(sed -n '/^Hardware/s/^.*: \(.*\)/\1/p' < /proc/cpuinfo)" in
            BCM*)
                # RPI kernels before 2023-11-24 print a 'Hardware: BCM2835' line
                get_rpi_model
                ;;
            *ODROIDC)
                __platform="odroid-c1"
                ;;
            *ODROID-C2)
                __platform="odroid-c2"
                ;;
            "Freescale i.MX6 Quad/DualLite (Device Tree)")
                __platform="imx6"
                ;;
            *ODROID-XU[34])
                __platform="odroid-xu"
                ;;
            "Allwinner sun8i Family")
                __platform="armv7-mali"
                ;;
            *)
                if [[ -e "/proc/device-tree/compatible" ]]; then
                    case "$(tr -d '\0' < /proc/device-tree/compatible)" in
                        *raspberrypi*)
                            get_rpi_model
                            ;;
                        *rockpro64*)
                            __platform="rockpro64"
                            ;;
                        *imx6dl*)
                            __platform="imx6"
                            ;;
                        *imx6q*)
                            __platform="imx6"
                            ;;
                        *rk3588*)
                            __platform="rk3588"
                            ;;
                    esac
                else
                    __platform="${architecture}"
                fi
                ;;
        esac
    fi

    # Check: Target KMS for platform
    if [[ -z "${__has_kms}" ]]; then
        iniConfig " = " '"' "${configdir}/all/emptypie.cfg"
        iniGet "force_kms"
        [[ "${ini_value}" == 1 ]] && __has_kms=1
        [[ "${ini_value}" == 0 ]] && __has_kms=0
    fi

    set_platform_defaults

    # If a function for the platform exists call it, otherwise default to 'native' platform
    if fnExists "platform_${__platform}"; then
        "platform_${__platform}"
    else
        platform_native
    fi
}

function set_platform_defaults() {
    __default_opt_flags="-O3"

    # Add platform name & 32bit or 64bit to platform flags
    __platform_flags=("${__platform}" "$(getconf LONG_BIT)bit")
    __platform_arch="$(uname -m)"
}

function cpu_armv7() {
    local cpu="${1}"
    if [[ -n "${cpu}" ]]; then
        __default_cpu_flags="-mcpu=${cpu} -mfpu=neon-vfpv4"
    else
        __default_cpu_flags="-march=armv7-a -mfpu=neon-vfpv4"
        cpu="cortex-a7"
    fi
    __platform_flags+=('arm' 'armv7' 'neon')
    __qemu_cpu="${cpu}"
}

function cpu_armv8() {
    local cpu="${1}"
    __default_cpu_flags="-mcpu=${cpu}"
    if isPlatform "32bit"; then
        __default_cpu_flags+=" -mfpu=neon-fp-armv8"
        __platform_flags+=('arm' 'armv8' 'neon')
    else
        __platform_flags+=('aarch64')
    fi
    __qemu_cpu="${cpu}"
}

function cpu_arm_state() {
    if isPlatform "32bit"; then
        __default_cpu_flags+=" -marm"
    fi
}

#function platform_conf_glext() {
    # Required For 'mali-fbdev' Headers To Define GL Functions
    #__default_cflags="-DGL_GLEXT_PROTOTYPES"
#}

function platform_rpi2() {
    cpu_armv7 "cortex-a7"
    __platform_flags+=('rpi' 'gles')
}

function platform_rpi3() {
    cpu_armv8 "cortex-a53"
    __platform_flags+=('rpi' 'gles')
}

function platform_rpi4() {
    cpu_armv8 "cortex-a72"
    __platform_flags+=('rpi' 'gles' 'gles3' 'gles31' 'gles32' 'vulkan')
}

function platform_rpi5() {
    cpu_armv8 "cortex-a76"
    __platform_flags+=('rpi' 'gles' 'gles3' 'gles31' 'gles32' 'vulkan')
}

function platform_odroid-c1() {
    cpu_armv7 "cortex-a5"
    cpu_arm_state
    __platform_flags+=('gles' 'mali')
}

function platform_odroid-c2() {
    cpu_armv8 "cortex-a72"
    cpu_arm_state
    __platform_flags+=('gles' 'mali')
}

function platform_odroid-xu() {
    cpu_armv7 "cortex-a7"
    cpu_arm_state
    #platform_conf_glext
    __platform_flags+=('gles' 'mali')
}

function platform_rockpro64() {
    cpu_armv8 "cortex-a53"
    __platform_flags+=('gles' 'kms')
}

function platform_native() {
    __default_cpu_flags="-march=native -mtune=native -pipe"
    __platform_flags+=('gl' 'vulkan')
    if [[ "${__has_kms}" -eq 1 ]]; then
        __platform_flags+=('kms')
    else
        __platform_flags+=('x11')
    fi
    # Add 'x86' platform flag for x86/x86_64 architectures
    [[ "$__platform_arch" =~ (i386|i686|x86_64) ]] && __platform_flags+=('x86')
}

function platform_armv7-mali() {
    cpu_armv7
    __platform_flags+=('gles' 'mali')
}

function platform_imx6() {
    cpu_armv7 "cortex-a9"
    [[ -d "/sys/class/drm/card0/device/driver/etnaviv" ]] && __platform_flags+=('gles' 'mesa' 'x11')
}

function platform_rk3588() {
    cpu_armv8 "cortex-a76.cortex-a55"
    __platform_flags+=('x11' 'gles' 'gles3' 'gles32')
}
