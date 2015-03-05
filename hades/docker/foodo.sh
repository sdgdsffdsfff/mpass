#!/bin/bash

##set +x

BASE_DIR=/letv/mpass/hades
source $BASE_DIR/conf.sh

CONTAINER_ROOT=/letv

TO_DOCKER_RUN=120
TO_RSYNC=120
TO_WSH5=5
TO_WSH60=60
TO_WSH600=600

WSH=$BASE_DIR/docker/wsh
WSHD=$BASE_DIR/docker/wshd

LOGFILE=$LOG_DIR/do.log

exec 2>>$LOGFILE

SCP_OPTS="-q -o StrictHostKeyChecking=no -o ConnectTimeout=3 "

function log()
{
    echo "$(date +%Y%m%d-%H%M%S): $@" >> $LOGFILE
    #echo "$(date +%Y%m%d-%H%M%S): $@"
}

function error_exit()
{
    log ">>> failed: $2"
    exit $1
}

function _get_app()
{
    local app_uri=$1
    local target_dir=$2
    local logfile=$3

    local proto=${app_uri%://*}
    if [ "$proto" = "file" ]; then
        local app_dir=${app_uri#*://}
		cp -aR $app_dir/* $target_dir/ >> $logfile 2>&1
        [ $? -ne 0 ] && { return 1; }
    elif [ "$proto" = "http" ]; then
        local now=$(date +%Y%m%d-%H%M%S)
        local tmpfile=$RUN_DIR/work/${now}.tgz
        wget -q $app_uri -O $image_file >> $logfile 2>&1 
        [ $? -ne 0 ] && { return 2; }
        tar xzf $tmpfile -C $targe_dir/ >> $logfile 2>&1
        rm -f $tmpfile
        [ $? -ne 0 ] && { return 3; }
	elif [ "$proto" = "rsync" ]; then
	## rsync://user@server:path
        local remote_path=${app_uri#*://}
	    local retry=0
        while :
        do
            log "rsync app from ($remote_path) ($target_dir/) ($retry)"
            rsync -aq --partial --delete -e 'ssh -o "StrictHostKeyChecking=no" ' $remote_path $target_dir/  >>$logfile 2>&1
            [ $? -eq 0 ] && { break; }
            retry=$(($retry+1))
            [ $retry -eq 3 ] && {
				return 1;
            }
            sleep 1
        done
	else
        return 10
    fi
    return 0
}

function instance_create()
{
    local instance_name=$1
    local info_file=$2
    source $info_file

    LOGFILE=$LOG_DIR/${instance_name}.log

    log ">>> instance_create begin: $arg_appid"
    local instance_dir=$INSTANCE_ROOT/$instance_name
    mkdir -p $instance_dir
    rm -rf $instance_dir/*
	
    mkdir -p $instance_dir/{app,logs}
    chmod 777 $instance_dir/logs

    local port_maps=""
    [ "$arg_port" != "0" ] && port_maps="-p $arg_port"

    _get_app $arg_app_uri $instance_dir/app/ $LOGFILE || {
        error_exit 107 "get app from $arg_app_uri failed";
    }

    local hostname="$arg_appid"
	local runcmd="$CONTAINER_ROOT/app/run.sh"; 
   	[ -e $instance_dir/app/run.sh ] && { 
		chmod +x $instance_dir/app/run.sh;
	} || {
		runcmd="";
	}
	
	log "docker run \
        --name "${arg_appid}_$instance_name" \
        -d \
        -v $instance_dir:$CONTAINER_ROOT \
        -h $hostname \
        $port_maps \
        $arg_imgid $runcmd"

    local container_id=$(docker run \
        --name "${arg_appid}_$instance_name" \
        -d \
        -v $instance_dir:$CONTAINER_ROOT \
        -h $hostname \
        $port_maps \
        $arg_imgid $runcmd)

    [ $? -ne 0 ] && { 
        rm -rf $instance_dir
        error_exit 101 "create container";
    }
    log "container_id: ($container_id)"
    [ "$container_id" == "" ] && {
        rm -rf $instance_dir
        error_exit 102 "invalid container id"
    }
	sleep 4
    docker inspect -f '{{.State.Running}}' $container_id |grep true >> $LOGFILE 2>&1
    [ $? -ne 0 ] && {
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 103 "container not in running state"
    }
    local container_dir=$DOCKER_DIR/containers/$container_id
    [ ! -d $container_dir ] && { 
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 105 "missing container directory"; 
    }
    local container_ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' $container_id)
    [[ $? -ne 0 || "$container_ip" = "" ]] && { 
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 106 "no container IP";
    }

    local public_port="0"
    [ "$arg_port" != "0" ] && { 
        public_port=$(docker port $container_id $arg_port |awk -F ":" '{print $2}'); 
		[ "$public_port" = "" ] && {
	        docker stop  $container_id >> $LOGFILE 2>&1
		    docker wait $container_id >> $LOGFILE 2>&1
			docker rm $container_id >> $LOGFILE 2>&1
	        rm -rf $instance_dir
		    error_exit 107 "missing public port";
		}
    }
    echo $container_id $container_ip $public_port
    log ">>> instance_create end: $appid ($container_id $container_ip ($public_port))"
}

function instance_delete()
{
    local instance_name=$1
    local container_id=$2
    local container_ip=$3

    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name

    log ">>> instance_delete begin: $container_id $container_ip $uid"
    local old_mem_size=$(lxc-cgroup -n $container_id memory.limit_in_bytes 2>/dev/null)
    [ -n "$old_mem_size" ] && {
        lxc-cgroup -n $container_id memory.memsw.limit_in_bytes $(($old_mem_size*5)) >/dev/null 2>&1
        lxc-cgroup -n $container_id memory.limit_in_bytes $(($old_mem_size*5)) >/dev/null 2>&1
    }

    local init_pid=$(docker inspect $container_id |grep "Pid" |awk '{print $2}')

    log "remove container"
    docker rm -f $container_id >> $LOGFILE 2>&1

    pid=$(ps ax|grep "lxc-start -n $container_id"|grep -v "grep" |awk '{print $1}')
    [ "$pid" != "" ] && {
        log "kill container pid: $pid"
        kill -9 $pid 2>/dev/null 
    }
    [ "$init_pid" != "" ] && {
        init_pid=${init_pid%*,}
        [ "$init_pid" != "0" ] && {
            log "kill init pid: $init_pid"
            kill -9 $init_pid 2>/dev/null
        }
    }

    [ -d $DOCKER_DIR/containers/${container_id}* ] && { 
        log "remove container dir"
        umount $DOCKER_DIR/containers/${container_id}*/rootfs
        rm -rf $DOCKER_DIR/containers/${container_id}*
        [ $? -ne 0 ] && {
            log "remove container dir failed"
        }
    }

    ### delete network device
    log "delete network device"
    ip link del $container_id 2>/dev/null
    /sbin/ifconfig -a |grep $container_id
    [ $? -eq 0 ] && {
        log "delete network device failed"
    }

    ### delete cgroup entries
    log "delete cgroups"
    find /cgroup/ -name "${container_id}*" |xargs -i find {} -depth -type d -print -exec rmdir {} \;
    find /cgroup/ -name "${container_id}*" |xargs rm -rf 

    ### check again
    docker ps -a |grep $container_id
    [ $? -eq 0 ] && {
        log "container still there, delete it again"
        docker rm $container_id >> $LOGFILE 2>&1
    }
    
    rm -rf $instance_dir
    log ">>> instance_delete end: $container_id $container_ip"
}

function active_container_list()
{
    docker ps -q
    [ $? -eq 0 ] && { exit 0; }
    ### docker server not in running state, use ps
    ps ax |grep "lxc-start -n" |grep -v "grep" |awk '{print $7}' |cut -c -12
}

function check_instances()
{
    instances="$@"
    ret=""
    for instance in $instances; do
        sock=/home/bae/share/instances/$instance/wshd.sock
        if [ ! -e $sock ]; then
            continue
        fi
        wsh --socket $sock /home/admin/runtime/check.sh >/dev/null 2>&1
        ### check.sh not exist, return 255. [IGNORE]
        if [ $? -ne 0 -a $? -ne 255 ]; then
            ret=$ret" $instance"
        else
            log "check $instance failed: $?" >> $LOGFILE
        fi
    done
    echo $ret
}

function max_instance_count()
{
    ##echo $DOCKER_MAX_INSTANCE_COUNT
    local mem_size=$(free -m |grep Mem:|awk '{print $2}')
    [ $? -ne 0 ] && { error_exit 1 "failed to get MEMORY info"; }
    #local cpu_num=$(cat /proc/cpuinfo |grep processor |wc -l)
    #[ $? -ne 0 ] && { error_exit 1 "failed to get CPU info"; }

    df -BM $CONTAINER_DISK >/dev/null 2>&1
    [ $? -ne 0 ] && { error_exit 1 "failed to get DISK info"; }
    local disk_size=$(df -BM $CONTAINER_DISK |sed '1d' |awk '{print $4}')
    mem_size=$(($mem_size-4096))
    [ $mem_size -lt 0 ] && { error_exit 1 "memory size <= 4G"; }
    local x0=$(($mem_size/$RES_MEM_LIMIT))
    disk_size=${disk_size:0:-1}
    local x1=$(($disk_size/$RES_DISK_LIMIT))
    [ $x0 -lt $x1 ] && { echo $x0; } || { echo $x1; }
}

function get_system_resource()
{
    local mem_size=$(free -m |grep Mem:|awk '{print $2}')
    [ $? -ne 0 ] && { error_exit 1 "failed to get MEMORY info"; }

    df -BM $CONTAINER_DISK >/dev/null 2>&1
    [ $? -ne 0 ] && { error_exit 1 "failed to get DISK info"; }
    local disk_size=$(df -BM $CONTAINER_DISK |sed '1d' |awk '{print $4}')
    disk_size=${disk_size:0:-1}
    echo $mem_size $disk_size
}

FUNC=$1
shift

$FUNC "$@"
exit 0

