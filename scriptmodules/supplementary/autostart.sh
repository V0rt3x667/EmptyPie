#!/usr/bin/env bash

# This file is part of the EmptyPie project.
#
# Please see the LICENSE file at the top-level directory of this distribution.

rp_module_id="autostart"
rp_module_desc="Auto-start EmulationStation / Pegasus / Kodi On Boot"
rp_module_section="config"

function _update_hook_autostart() {
    if [[ -f "/etc/profile.d/10-emulationstation.sh" ]]; then
        enable_autostart
    fi
}

function _autostart_script_autostart() {
    local mode="${1}"

    # Delete Old Startup Script
    rm -f "/etc/profile.d/10-emulationstation.sh"

    local script="${configdir}/all/autostart.sh"

    cat >/etc/profile.d/10-emptypie.sh <<_EOF_
# Launch Autostart Apps
if [ "\`tty\`" = "/dev/tty1" ] && [ -z "\${DISPLAY}" ] && [ "\${USER}" = "${__user}" ]; then
    bash "${script}"
fi
_EOF_
    touch "${script}"

    # Delete Any Previous Entries For EmulationStation & kodi In "autostart.sh"
    sed -i '/#auto/d' "${script}"
    sed -i '$a'\' "${script}"
    case "${mode}" in
        kodi)
            echo -e "kodi-standalone #auto\nemulationstation #auto" >>"${script}"
            ;;
        pegasus)
            echo "pegasus-fe #auto" >> "${script}"
            ;;
        es|*)
            echo "emulationstation #auto" >>"${script}"
            ;;
    esac
    chown "${__user}":"${__group}" "${script}"
}

function enable_autostart() {
    local mode="${1}"

    if isPlatform "x11"; then
        mkUserDir "${home}/.config/autostart"
        ln -sf "/usr/share/applications/emptypie.desktop" "${home}/.config/autostart/"
    else
        if [[ "$(cat /proc/1/comm)" == "systemd" ]]; then
            mkdir -p "/etc/systemd/system/getty@tty1.service.d/"
            cat >"/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<_EOF_
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin "${__user}" --noclear %I \$TERM
_EOF_
        fi

        _autostart_script_autostart "${mode}"
    fi
}

function disable_autostart() {
    #local login_type="${1}"
    #[[ -z "${login_type}" ]] && login_type="B2"
    if isPlatform "x11"; then
        rm "${home}/.config/autostart/emptypie.desktop"
    else
        if [[ "${__chroot}" -eq 1 ]]; then
            systemctl set-default graphical.target
            ln -fs "/lib/systemd/system/getty@.service" "/etc/systemd/system/getty.target.wants/getty@tty1.service"
        fi
        if [[ "$(cat /proc/1/comm)" == "systemd" ]]; then
            rm -f "/etc/systemd/system/getty@tty1.service.d/autologin.conf"
            systemctl set-default graphical.target
            #systemctl enable lightdm.service
        fi
        rm -f /etc/profile.d/10-emulationstation.sh
        rm -f /etc/profile.d/10-emptypie.sh
    fi
}

function remove_autostart() {
    disable_autostart
}

function gui_autostart() {
    cmd=(dialog --backtitle "${__backtitle}" --menu "Choose The Desired Boot Behaviour" 22 76 16)
    local has_pegasus=0
    local has_kodi=0

    command -v pegasus-fe >/dev/null && has_pegasus=1
    command -v kodi-standalone >/dev/null && has_kodi=1

    while true; do
        if isPlatform "x11"; then
            local x11_autostart
            if [[ -f "${home}/.config/autostart/emptypie.desktop" ]]; then
                options=(1 "Autostart EmulationStation After Login (Enabled)")
                x11_autostart=1
            else
                options=(1 "Autostart EmulationStation After Login (Disabled)")
                x11_autostart=0
            fi
        else
            options=(
                1 "Start EmulationStation At Boot"
            )
            [[ "${has_kodi}" -eq 1 ]] && options+=(2 "Start Kodi At Boot (Exit Starts EmulationStation)")
            [[ "${has_pegasus}" -eq 1 ]] && options+=(3 "Start Pegasus At Boot")
            options+=(
                E "Manually Edit ${configdir}/all/autostart.sh"
            )
            options+=(DL "Boot To Desktop (Require Login)")
        fi
        choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
        if [[ -n "${choice}" ]]; then
            case "${choice}" in
                1)
                    if isPlatform "x11"; then
                        if [[ "${x11_autostart}" -eq 0 ]]; then
                            enable_autostart
                            printMsgs "dialog" "EmulationStation Is Set To Autostart After Login"
                        else
                            disable_autostart
                            printMsgs "dialog" "Autostarting Of EmulationStation Is Disabled"
                        fi
                        x11_autostart=$((x11_autostart ^ 1))
                    else
                        enable_autostart
                        printMsgs "dialog" "EmulationStation Is Set To Launch At Boot"
                    fi
                    ;;
                2)
                    enable_autostart kodi
                    printMsgs "dialog" "Kodi Is Set To Launch At Boot"
                    ;;
                3)
                    enable_autostart pegasus
                    printMsgs "dialog" "Pegasus Is Set To Launch At Boot"
                    ;;
                E)
                    editFile "${configdir}/all/autostart.sh"
                    ;;
                DL)
                    disable_autostart B3
                    printMsgs "dialog" "Booting To Desktop (Require Login)"
                    ;;
            esac
        else
            break
        fi
    done
}
