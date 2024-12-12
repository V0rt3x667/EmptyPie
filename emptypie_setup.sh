#!/usr/bin/env bash

# This file is part of the EmptyPie project.
#
# Please see the LICENSE file at the top-level directory of this distribution.

scriptdir="$(dirname "${0}")"
scriptdir="$(cd "${scriptdir}" && pwd)"

"${scriptdir}/emptypie_packages.sh" setup gui
