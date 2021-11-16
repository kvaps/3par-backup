#!/bin/bash
IP=$1
PATTERN=$2
JOBS=${JOBS:-3}
FIRST_LUN=${FIRST_LUN:-100}

if [ -z "$PATTERN" ]; then
  echo "Usage: $0 <3par> <pattern>"
  exit 1
fi

exec_async() {
  # content of script exec-async.sh
  joblist=($(jobs -p))
  while (( ${#joblist[*]} >= $JOBS )); do
      sleep 1
      joblist=($(jobs -p))
  done
  echo "Starting job: $*"
  $* &
}

backup_vv() {
  LUN=$1 VV=$2 HOST=$HOST IP=$IP bash -s <<\EOT
    # cleanup broken devices (just in case)
    OLD_VVS=$(ssh "3paradm@$IP" showvlun -host "$HOST" </dev/null | awk "\$1 == $LUN && \$NF == \"host\" {print \$2}" )
    for OLD_VV in $OLD_VVS; do
      yes | ssh "3paradm@$IP" removevlun "$OLD_VV" "$LUN" "$HOST"
      iscsiadm -m session --rescan "$RPORTALS" >/dev/null

      ISCSI_DISKS=$(iscsiadm -m session -P3 | grep "Lun: $LUN$" -A1 | awk '/Attached scsi disk/ {print $4}')
      for device in ${ISCSI_DISKS}; do
        if [ -e /dev/${device} ] && ! fdisk -l /dev/${device} >/dev/null 2>&1; then
            blockdev --flushbufs /dev/${device}
            echo 1 > /sys/block/${device}/device/delete
        fi
      done
    done

    yes | ssh "3paradm@$IP" removevv "$VV-backup" 2>/dev/null

    # attach
    yes | ssh "3paradm@$IP" createsv -ro -exp 7d "$VV-backup" "$VV"
    yes | ssh "3paradm@$IP" createvlun "$VV-backup" "$LUN" "$HOST"
    WWN=$(ssh "3paradm@$IP" showvv -showcols VV_WWN "$VV-backup" </dev/null | awk 'FNR == 2 {print tolower($1)}')
    iscsiadm -m session --rescan "$RPORTALS" >/dev/null
    ISCSI_DISKS=$(iscsiadm -m session -P3 | grep "Lun: $LUN$" -A1 | awk '/Attached scsi disk/ {print $4}')
    multipath $ISCSI_DISKS
    DM_HOLDER=$(dmsetup ls -o blkdevname | awk "\$1 == \"3$WWN\" {gsub(/[()]/,\"\");print \$2}")
    DM_SLAVE=$(ls -1 /sys/block/${DM_HOLDER}/slaves)

    cleanup() {
      # detach
      multipath -f "3${WWN}"
      unset device
      for device in ${DM_SLAVE}; do
        if [ -e /dev/${device} ]; then
            blockdev --flushbufs /dev/${device}
            echo 1 > /sys/block/${device}/device/delete
        fi
      done
    }
    trap cleanup EXIT

    echo Processing $VV-backup
    (
      set -x
      dd if="/dev/$DM_HOLDER" of=/dev/null status=progress bs=16M
    )
    cleanup
    trap EXIT

    yes | ssh "3paradm@$IP" removevlun "$VV-backup" "$LUN" "$HOST"
    yes | ssh "3paradm@$IP" removevv "$VV-backup"
EOT
}

# Setup host
INITIATOR_NAME=$(awk -F= '{print $2}' /etc/iscsi/initiatorname.iscsi)
HOST=$(hostname -s)

if [ -z "$INITIATOR_NAME" ] || [ -z "$HOST" ] || [ -z "$IP" ]; then
  echo "INITIATOR_NAME, HOST or IP is empty!" >&2
  exit 1
fi

ssh "3paradm@$IP" createhost -iscsi "$HOST" "$INITIATOR_NAME"

# ---------------------------

RPORTALS=$(ssh "3paradm@$IP" showport -iscsivlans | tail -n+2 | head -n-2 | awk '{print $3}')
LPORTALS=$(sudo iscsiadm -m session -o show | awk -F '[ :,]+' '{print $3}')

# iSCSI login
for RPORTAL in $RPORTALS; do
  for LPORTAL in $LPORTALS; do
    if [ "$LPORTALS" = "$RPORTAL" ]; then
      continue 2
    fi
  done
  sudo iscsiadm -m discovery -t sendtargets -p "$RPORTAL"
  sudo iscsiadm -m node -l all -p "$RPORTAL"
done

VVS=$(ssh "3paradm@$IP" showvv -showcols Name "$PATTERN" | head -n-2 | tail -n+2 | grep -v '\-backup ')
VVS_WC=$(echo "$VVS" | wc -l)
PORTION="$(($VVS_WC/$JOBS))"

# Set traps to kill background processes
trap "exit" INT TERM
trap "kill 0" EXIT

## Perform backup
while read LUN VV; do
  exec_async backup_vv "$LUN" "$VV"
done < <(echo "$VVS" | awk -v FIRST_LUN="$FIRST_LUN" -v COUNT="$JOBS" '{ f=(f%COUNT)+1 ; print FIRST_LUN + f-1, $0 }')


iscsiadm -m session --rescan $RPORTALS

# iSCSI logout
sudo iscsiadm -m session -o show | while read _ _ LPORTAL _; do
  for RPORTAL in $RPORTALS; do
    if [ "$LPORTAL" = "$RPORTAL" ]; then
      sudo iscsiadm --mode node -u -p "$RPORTAL"
    fi
  done
done

ssh "3paradm@$IP" removehost "$HOST"
