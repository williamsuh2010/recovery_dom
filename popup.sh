#!/bin/sh
if systemctl -q is-active lsi_msm.service; then
    ./etc/profile.d/msm.sh
    cd "$MSM_HOME/MegaPopup"
    ./popup &
    cd -
fi
