#!/bin/bash
# Manage ganesha cluster instances. Written to work together with
# keepalived and its state changes (MASTER|BACKUP|FAULT)

MODE=''
INSTANCE=''
INSTANCE_LIST=/etc/ganesha/instance_list
STATES_DIR='/var/run'
GRG_CEPH_CONF='/etc/ceph/ceph.conf' GRG_USER='admin'
GRG_NAMESPACE='ganesha'
GRG_POOL='nfs-ganesha'
MAX_FAILS=3
MONITOR_INTERVAL=2
FAULT_INTERVAL=15
IP_FLAP_WAIT=10
CLUSTERNAME='ganesha-cluster'
LOG_TIMESTAMP="%F %H:%M:%S"
LOGFILE=/var/log/ganesha-keepalived.log
FSAL=vfs

REQUIRED_PKGS=(
"nfs-ganesha-rados-grace"
)
ALLOWED_MODES=(
  "monitor"
  "backup"
  "fault"
  "master"
  "check"
  "reset"
  "enforce"
  "stop"
)

function print_help(){
  echo
  echo "Manage nfs-ganesha instances via keepalived

Usage:
$0 {`for mode in ${ALLOWED_MODES[@]};do echo -n "${mode}|";done| sed -e 's/|$//g'`} --instance {instance name}

Modes:
  monitor  starts a watcher on ganesha instance, keeping track of failures and state in /var/run
  reset    reset the failure count. after $MAX_FAILS, it will mark instance as failed and keepalived will give up on restarting it
  enforce  start enforcing on all but the instance passed. useful when you want to stop the instance to make sure grace is on before doing anything.
  master   for use with keepalived notify_master
  backup   for use with keepalived notify_backup
  fault    for use with keepalived notify_fault
  stop     for use with keepalived notify_stop

Required parameters:
  --instance {STRING}  the instance name

Optional parameters:
  --max-fails {INT}  maximum allowed keepalived 'FAULT' occurences before giving up completely (restart of keepalived or $0 reset --instance {instance} to reset)
  --monitor-interval {INT}  time in sec between checks that ganesha process is running (default $MONITOR_INTERVAL)
  --fault-interval {INT}  time in sec to wait between attempting to restart ganesha after a fault (default $FAULT_INTERVAL)
  --fsal {vfs|cephfs}  the FSAL used for exports (defaults $FSAL)
  --logfile {/path/to/log}}  log file to use (default $LOGFILE)
"
}

args=($@)
for arg in ${args[*]}
do
    pos=$(($count+1))
    case $arg in
    "--instance")
        INSTANCE=${args[$pos]}
    ;;
    "--max-fails")
        MAX_FAILS=${args[$pos]}
    ;;
    "--fault-interval")
        FAULT_INTERVAL=${args[$pos]}
    ;;
    "--monitor-interval")
        MONITOR_INTERVAL=${args[$pos]}
    ;;
    "--fsal")
        FSAL=${args[$pos]}
    ;;
    "-h")
        print_help
        exit
    ;;
    "-help")
        print_help
        exit
    ;;
        *)
        :
    ;;
    esac
    count=$(($count+1))
done

function logger() {
  echo "`date +"$LOG_TIMESTAMP"` $INSTANCE: $1" >> $LOGFILE
}

## Check required pkgs
for pkg in ${REQUIRED_PKGS[*]}
do
  if ! dpkg -s $pkg >/dev/null 2>&1
  then
    echo "The package '"$pkg"' is not installed. The following system packages are required for this script:"
    echo "${REQUIRED_PKGS[*]}"
    exit 1
  fi
done


function init_instance() {
  echo "init" > ${STATE_FILE}
}

function fail_instance() {
  echo $((${MAX_FAILS}+1)) > ${FC_FILE}
  echo "failed" > ${STATE_FILE}
  systemctl stop nfs-ganesha@${INSTANCE}
}

function reset_instance_failures() {
  logger "resetting failure count"
  echo 0 > ${FC_FILE}
}

function trigger_grace() {
  $GRG_CMD start $INSTANCE
}

function set_enforce() {
  for instance in `cat $INSTANCE_LIST | awk '{print $1}'`
  do
    if [[ "$instance" != "$INSTANCE" ]]
    then
      ($GRG_CMD dump $instance | grep $instance | grep E) || ($GRG_CMD enforce $instance && logger "setting enforce flag for $instance")
    fi 
  done 
}

function check_instance() {
  if kill -0 $(cat ${STATES_DIR}/ganesha-${INSTANCE}.pid) > /dev/null 2>&1
  then
    echo 0
  else
    echo 1
  fi
}

function increment_failcount() {
  failcount=`cat $FC_FILE`
  failcount=$((${failcount}+1))
  echo $failcount > $FC_FILE
  logger "instance has recorded $failcount faults"
}

function check_instance_failed (){
  failcount=`cat $FC_FILE`
  if [[ $failcount -gt $MAX_FAILS ]]
  then
    echo "failed" > $STATE_FILE
    logger "nfs-ganesha service has exceeded maximum allowed failures ($MAX_FAILS) and will not be auto started again. Check ganesha instance logs for errors and use '$0 reset --instance $INSTANCE' or restart keepalived if you want to try starting again."
    exit 1
  fi
}

function keepalived_check() {
  STATE=`cat ${STATE_FILE}`
  if [[ "$STATE" == "init" ]] || [[ "$STATE" == "up" ]]
  then
    exit 0
  else
    exit 1
  fi
}

function monitor_instance() {
  if [[ `ps -ef | grep "$0 monitor" | grep "$INSTANCE" | egrep -v "grep|$$" | wc -l` -gt 0 ]]
  then
    logger "monitor already running."
    exit 0
  fi
  while true
  do
    check_instance_failed
    if [[ $(check_instance) -ne 0 ]]
    then
      echo "down" > $STATE_FILE
    else
      echo "up" > $STATE_FILE
    fi
    sleep $MONITOR_INTERVAL
  done
}

function test_exports() {
  exports=$(cat /etc/ganesha/ganesha-ga1.conf | grep -i path | sed -e 's/.*[Pp]ath.*=[^/]*\(\/.*\)\;/\1/g')
  for e in $exports
  do
    test -d $e && test -x $e
    if [[ $? -ne 0 ]]
    then
      logger "Error with export ${e}, check the directory exists and is accessible. Failing instance ${INSTANCE} due to bad export dir."
      fail_instance
      exit 1
    fi
  done
}

function kill_monitor () {
  mon_pid=`ps -ef | grep "$0 monitor" | grep "$INSTANCE" | egrep -v "grep" | awk '{print $2}'`
  if [[ "$mon_pid" != "" ]]; then kill $mon_pid; fi
}

function kill_instance() {
  kill $(cat ${STATES_DIR}/ganesha-${INSTANCE}.pid)
}

function stop_instance() {
  if systemctl status nfs-ganesha@${INSTANCE} > /dev/null; then set_enforce; systemctl stop nfs-ganesha@${INSTANCE} && logger "Stopping instance $INSTANCE due to $1";fi
}

function set_hostname() {
  hostname $CLUSTERNAME || (logger "Error setting hostname!" && exit 1)
  echo $CLUSTERNAME > /etc/hostname
}

function keepalived_backup() {
  logger "running BACKUP routine"
  #set_enforce 
  kill_monitor
  stop_instance BACKUP
  init_instance
  #trigger_grace
}

function keepalived_fault() {
  logger "running FAULT routine"
  #set_enforce
  kill_monitor
  stop_instance FAULT
  increment_failcount
  check_instance_failed
  sleep $FAULT_INTERVAL
  init_instance
  #trigger_grace
}

function keepalived_stop() {
  logger "running STOP routine"
  #set_enforce
  kill_monitor
  stop_instance STOP
}


function keepalived_master() {
  logger "starting MASTER routine"
  check_instance_failed
  set_hostname
  #set_enforce
  if [[ "$FSAL" == "vfs" ]]; then test_exports; fi
  ## Wait some time in case keepalived flaps and moves IP addr around
  sleep $IP_FLAP_WAIT
  ipaddr=$(cat $INSTANCE_LIST | grep $INSTANCE | cut -d' ' -f2)
  if ! ip a | grep "$ipaddr"; then logger "instance ip $ipaddr not hosted here, not starting $INSTANCE" ;exit 1; fi
  
  # Otherwise continue
  logger "Found IP $ipaddr, starting instance" && systemctl start nfs-ganesha@${INSTANCE}
  $0 monitor --instance ${INSTANCE} &
  if [[ `ps -ef | grep "$0 monitor" | grep "$INSTANCE" | egrep -v "grep" | wc -l` -lt 1 ]]
  then
    logger "couldn't start monitor."
    fail_instance
  fi
  #trigger_grace
}

function reset() { 
  reset_instance_failures
  init_instance
}

## Main
STATE_FILE=${STATES_DIR}/ganesha-${INSTANCE}.state
FC_FILE=${STATES_DIR}/ganesha-${INSTANCE}.fc
GRG_CMD="ganesha-rados-grace --userid $GRG_USER --cephconf $GRG_CEPH_CONF -n $GRG_NAMESPACE --pool $GRG_POOL"

if [[ "$INSTANCE" == "" ]] || ([[ "$INSTANCE" != "" ]] && [[ ! `cat $INSTANCE_LIST | grep "$INSTANCE"` ]]) ; then logger "Invalid instance, use --instance to provide the instance name.";fi

MODE=$1
case $MODE in
  "reset")
    reset
  ;;
  "enforce")
    set_enforce
  ;;
  "monitor")
    monitor_instance
  ;;
  "master")
    keepalived_master
  ;;
  "check")
    keepalived_check
  ;;
  "backup")
    keepalived_backup
  ;;
  "fault")
    keepalived_fault
  ;;
  "stop")
    keepalived_stop
  ;;
  *)
    echo "Incorrect mode '$MODE' supplied." 
    print_help
  ;;
esac
