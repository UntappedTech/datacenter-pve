#!/bin/bash
TEMPLATE_DIR=/etc/scripts/templates
WORKING_DIR="$(dirname $(readlink -f ${BASH_SOURCE}))"
echo -e $WORKING_DIR

# pct exec $1 mkdir /etc/update-motd.d/template
#echo "Pushing motd script to $1"
#pct push $1 $WORKING_DIR/templates/motd /etc/update-motd.d/lxc
#pct exec $1 -- chmod +x /etc/update-motd.d/lxc
#echo "motd script now executable"

# Add certificates mountpoint if not exists
if [[ -z $(pct config $1 | grep -E 'mp255.*certs') ]]; then
    pct set $1 --mp255 /srv/certs,mp=/certs,ro=1
    echo "Added /certs mountpoint"
fi

# Add .bashrc files
pct exec $1 -- bash -c 'mkdir -p /root/.bashrc.d && chmod 700 /root/.bashrc.d'
# pct exec $1 -- bash -c '[ grep -eq "$BASHRC_START" /root/.bashrc ] && echo -e "{MK_ROOM}{BASHRC_START}{MK_ROOM}for FILE in ~/.bashrc.d/*; do \n\tsource \$FILE \ndone\n" >> /root/.bashrc'

for FILE in `ls $WORKING_DIR/templates/bashrc`; do
   echo -e "pushing file /root/.bashrc.d/$FILE"
   pct push $1 $WORKING_DIR/templates/bashrc/$FILE /root/.bashrc.d/$FILE
done
pct exec $1 -- bash -c 'chmod +x /root/.bashrc.d/* && /root/.bashrc.d/00-lxc-run-once.sh'
