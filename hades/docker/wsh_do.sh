#!/bin/bash

##set +x

source /home/bae/baeng/hades/conf.sh

HOST_SHARE_ROOT=/home/bae/share
GUEST_SHARE_ROOT=/home/admin/share
IMAGE_ROOT=$HOST_SHARE_ROOT/imagecaches
ADDONS_ROOT=$HOST_SHARE_ROOT/addons
INSTANCE_ROOT=$HOST_SHARE_ROOT/instances
LOG_ROOT=$HOST_SHARE_ROOT/logs
LXCDO_SCRIPT=$GUEST_SHARE_ROOT/instance/do.sh

TO_DOCKER_RUN=120
TO_RSYNC=120
TO_WSH5=5
TO_WSH60=60
TO_WSH600=600

WSH=/home/bae/baeng/hades/docker/wsh
WSHD=/home/bae/baeng/hades/docker/wshd

LOGFILE=/home/bae/logs/baeng/hades/do.log
exec 2>>$LOGFILE

SSH_OPTS="-t -t -o StrictHostKeyChecking=no -o ConnectTimeout=5 "
SCP_OPTS="-q -o StrictHostKeyChecking=no -o ConnectTimeout=3 "

function log()
{
    echo "$(date +%Y%m%d-%H%M%S): $@" >> $LOGFILE
}

function error_exit()
{
    log ">>> failed: $2"
    exit $1
}

function _get_container_image_id()
{
    echo $DOCKER_BASE_IMAGE_ID
}

function _add_port_rule()
{
	local proto=$1
	local p1=$2
	local p2=$3
	local container_id=$4
	local container_ip=$5

	log "adding rule: ($container_id $proto $p1 => $container_ip:$p2)"
	iptables -t nat -C BAEPORT -p $proto -m $proto --dport $p1 -j DNAT --to-destination $container_ip:$p2 -m comment --comment $container_id >/dev/null 2>&1
	[ $? -eq 0 ] && { log "WARNING: rule exist already"; return 0; }

	local retry=0
	while :
	do
		iptables -t nat -I BAEPORT -p $proto -m $proto --dport $p1 -j DNAT --to-destination $container_ip:$p2 -m comment --comment $container_id >> $LOGFILE 2>&1
        [ $? -eq 0 ] && { break; }
		retry=$(($retry+1))
		[ $retry -eq 3 ] && {
			log "add rule failed: ($container_id $proto $p1 => $container_ip:$p2)"
			return 1
		} 
		sleep 1
	done
	return 0
}

function _del_port_rule()
{
	local proto=$1
	local p1=$2
	local p2=$3
	local container_id=$4
	local container_ip=$5

	log "deleting rule: ($container_id $proto $p1 => $container_ip:$p2)"
	iptables -t nat -C BAEPORT -p $proto -m $proto --dport $p1 -j DNAT --to-destination $container_ip:$p2 -m comment --comment $container_id >/dev/null 2>&1
	[ $? -ne 0 ] && { log "WARNING: rule not exist"; return 0; }

	local retry=0
	while :
	do
		iptables -t nat -D BAEPORT -p $proto -m $proto --dport $p1 -j DNAT --to-destination $container_ip:$p2 -m comment --comment $container_id >> $LOGFILE 2>&1
        [ $? -eq 0 ] && { break; }
		retry=$(($retry+1))
		[ $retry -eq 3 ] && {
			log "delete rule failed: ($container_id $proto $p1 => $container_ip:$p2)"
			return 1
		} 
		sleep 1
	done
	return 0
}

function runtime_install()
{
    local runtime_type=$1
    local image_location=$2
    local image_md5=$3
    local version=$4

    log ">>> runtime_install begin: $runtime_type $image_location $image_md5 $version"
    [ "$image_md5" != "" ] && {
        [ -d $IMAGE_ROOT/$runtime_type ] && {
            [ -L $IMAGE_ROOT/$runtime_type ] && {
                local tmp=$(readlink $IMAGE_ROOT/$runtime_type)
                [ $? -eq 0 ] && {
                    local local_md5=$(basename $tmp)
                    local image_name="v"$version"_"$image_md5
                    log ">>> image_name=$image_name, local_md5=$local_md5"
                    [ "$image_name" = "$local_md5" ] && {
                        log "install success: local runtime image has same MD5 $local_md5 as remote"
                        return 0
                    } || {
                        log "remote MD5 ($image_md5) is diff with local ($local_md5)"
                    }
                }
            }
        }
    }
    local proto=${image_location%://*}
    local image_file=""
    if [ "$proto" = "file" ]; then
        image_file=${image_location#*://}
        [ ! -f $image_file ] && { error_exit 2 "$image_file not exist"; }
    elif [ "$proto" = "http" ]; then
        local now=$(date +%Y%m%d-%H%M%S)
        image_file=$RUN_DIR/work/${runtime_type}.${now}
        log "wget -q $image_location -O $image_file"
        wget -q $image_location -O $image_file 
        [ $? -ne 0 ] && { error_exit 2 "download $image_location failed"; }
    else
        error_exit 1 "invalid proto $proto"
    fi

    local new_md5=$(md5sum $image_file |awk '{print $1}')
    local v_name="v"$version"_"$new_md5
    local image_dir=$IMAGE_ROOT/$runtime_type.images/$v_name
    rm -rf $image_dir
    mkdir -p $image_dir
    log ">>> image_file=$image_file image_dir=$image_dir"
    tar xzf $image_file -C $image_dir
    [ $? -ne 0 ] && {
        [ "$proto" = "http" ] && { rm -f $image_file; }
        error_exit 3 "uncompress image file $image_file failed"
    }

    chown bae:bae $image_dir -R
    rm -rf $IMAGE_ROOT/$runtime_type
    ln -sf $runtime_type.images/$v_name $IMAGE_ROOT/$runtime_type >>$LOGFILE 2>&1
    [ $? -ne 0 ] && {
        [ "$proto" = "http" ] && { rm -f $image_file; }
        error_exit 4 "ln -sf $image_dir $IMAGE_ROOT/$runtime_type failed"
    }
    #save 5 images,del others
    local image_dir="$IMAGE_ROOT/$runtime_type.images/"
    local image_list=`ls -lt $image_dir | awk '{print $9}' | sed '/^$/d'`
    local image_list_num=`ls -lt $image_dir | awk '{print $9}' | sed '/^$/d' | wc | awk '{print $1}'`
    for ((i=1;i<=$image_list_num;i++)); do
        if [ $i -gt $SAVE_IMAGE_NUM ]; then
            name=`ls -lt $image_dir | awk '{print $9}' | sed '/^$/d' | sed -n $i'p'`
            log ">>> $i name=$name"
            if [ "$name" != "$v_name" ] && [ "$name" != "" ]; then
                log ">>> rm $IMAGE_ROOT/$runtime_type.images/$name"
                rm -rf $IMAGE_ROOT/$runtime_type.images/$name
            fi
        fi
    done
    log ">>> runtime_install end: $runtime_type $image_location $image_md5"
}

function runtime_update()
{
    local instance_name=$1
    local runtime_type=$2
    local uid=$3

    LOGFILE=$LOG_DIR/${instance_name}.log

    log ">>> runtime_update begin: $runtime_type $uid"

    [ ! -L $IMAGE_ROOT/$runtime_type ] && { error_exit 100 "$runtime_type must be symbolic link"; }   

    local instance_dir=$INSTANCE_ROOT/$instance_name
    cp -f /home/bae/baeng/hades/docker/lxcdo.sh $instance_dir/do.sh
    $WSH --timeout 180 --socket $instance_dir/wshd.sock $LXCDO_SCRIPT runtime_update $runtime_type "$uid" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && {
        error_exit 109 "runtime_update fialed, cmd : $WSH --socket $instance_dir/wshd.sock $LXCDO_SCRIPT runtime_update $runtime_type "$uid">>$LOGFILE ";
    }   
    log ">>> runtime_update end: $instance_name $runtime_type $uid "
}

function instance_create()
{
    local instance_name=$1
    local info_file=$2
    source $info_file

    LOGFILE=$LOG_DIR/${instance_name}.log

    log ">>> instance_create begin: $appid $runtime_type $uid"

    [ ! -L $IMAGE_ROOT/$runtime_type ] && { error_exit 100 "$runtime_type must be symbolic link"; }  

    local instance_dir=$INSTANCE_ROOT/$instance_name
    mkdir -p $instance_dir
    rm -rf $instance_dir/*

    local log_dir=$LOG_ROOT/$instance_name
    mkdir -p $log_dir
    rm -rf $log_dir/*
 
    cp -f $WSHD $instance_dir/
    cp -f /home/bae/baeng/hades/docker/rlimit.conf $instance_dir/
    cp -f /home/bae/baeng/hades/docker/policy-rc.d $instance_dir/
    cp -f /home/bae/baeng/hades/docker/handle_appconf.py $instance_dir/

    local port_opts=""
    for pair in $port_maps; do
        local p1=${pair%=*}
        local p2=${pair#*=}
        port_opts="$port_opts -p $p1:$p2"
    done

    local dns_opts=""
    for dns in $CONTAINER_DNS_SERVERS; do
        dns_opts="$dns_opts -dns=$dns"
    done

    local image_id=$(_get_container_image_id $runtime_type)

    [[ "$mem_size" = "" || "$mem_size" -lt "64" || "$mem_size" -gt 2048 ]] && {
        mem_size=$RES_MEM_LIMIT
    }

    local hostname="$appid"
    local container_id=$(timeout $TO_DOCKER_RUN docker run \
        -d \
        -v $IMAGE_ROOT:$GUEST_SHARE_ROOT/imagecaches:ro \
        -v $ADDONS_ROOT:$GUEST_SHARE_ROOT/addons:ro \
        -v $instance_dir:$GUEST_SHARE_ROOT/instance \
        -v $log_dir:/home/bae/log \
        -h $hostname \
        -m $(($mem_size * 1024 * 1024)) \
        $port_opts \
        $dns_opts \
        $image_id /home/admin/share/instance/wshd --rlimit /home/admin/share/instance/rlimit.conf --run /home/admin/share/instance 2>>$LOGFILE
    )
    [ $? -ne 0 ] && { 
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 101 "create container";
    }
    log "container_id: ($container_id)"
    [ "$container_id" == "" ] && {
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 102 "invalid container id"
    }
    docker inspect $container_id |grep '"Running": true' >> $LOGFILE 2>&1
    [ $? -ne 0 ] && {
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 103 "container not in running state"
    }
    local long_id=$(docker inspect $container_id|grep "ID" |awk '{gsub(/[",]/, "", $2); print $2}')
    [ $? -ne 0 ] && {
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 104 "missing container long id"
    }
    local container_dir=$DOCKER_DIR/containers/$long_id
    [ ! -d $container_dir ] && { 
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 105 "missing container directory"; 
    }

    local container_ip=$(docker inspect $container_id|grep "IPAddress" |awk '{gsub(/[",]/, "", $2); print $2}')
    [[ $? -ne 0 || "$container_ip" = "" ]] && { 
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 106 "no container IP";
    }
    log "$container_id $container_ip" 

    if [ "$app_location" != "" ]; then
    ### for local debug purpose
        cp -aR $app_location $instance_dir/app >> $LOGFILE 2>&1
        [ $? -ne 0 ] && {
            docker stop $container_id >> $LOGFILE 2>&1
            docker wait $container_id >> $LOGFILE 2>&1
            docker rm $container_id >> $LOGFILE 2>&1
            rm -rf $instance_dir
            rm -rf $log_dir
            error_exit 107 "copy code from $app_location";
        }
    else
        local retry=0
        while :
        do
            local index=$(($RANDOM%${#FILE_SERVERS[@]}))
            local file_server=${FILE_SERVERS[$index]}
            log "rsync code from fileserver $file_server ($retry)"
            timeout $TO_RSYNC rsync -aq --partial --delete -e 'ssh -o "StrictHostKeyChecking=no" ' $FILE_SERVER_USER@$file_server:/home/bae/wwwdata/htdocs/$appid/ $instance_dir/app/ >>$LOGFILE 2>&1
            [ $? -eq 0 ] && { break; }
            retry=$(($retry+1))
            [ $retry -eq 3 ] && {
                docker stop $container_id >> $LOGFILE 2>&1
                docker wait $container_id >> $LOGFILE 2>&1
                docker rm $container_id >> $LOGFILE 2>&1
                rm -rf $instance_dir
                rm -rf $log_dir
                error_exit 107 "rsync code from fileserver"; 
            }
            sleep 1
        done
    fi

    local bae_profile=$instance_dir/bae_profile
    echo "export SERVER_SOFTWARE=bae/3.0"         >> $bae_profile
    echo "export BAE_ENV_APPID=$appid"            >> $bae_profile
    echo "export BAE_ENV_LOG_HOST=$DOCKER0_IP"    >> $bae_profile
    echo "export BAE_ENV_LOG_PORT=7000"           >> $bae_profile

    cp -f /home/bae/baeng/hades/docker/lxcdo.sh $instance_dir/do.sh 

    local n=0
    while [ $n -lt 5 ]
    do
       [ -e $instance_dir/wshd.sock ] && {
           break
       }
       n=$(($n+1))
       log "wshd.sock is not ready, wait"
       sleep 1
    done
    [ $n -eq 5 ] && {
        docker stop $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 110 "missing wshd.sock"
    }

    ### save resource info
    echo "MEMORY_SIZE $mem_size" > $instance_dir/resource.info

    log "runtime_install"
    local op_timeout=$TO_WSH60
    [ "$runtime_type" = "custom" ] && { op_timeout=$TO_WSH600; }
    $WSH --timeout $op_timeout --socket $instance_dir/wshd.sock $LXCDO_SCRIPT runtime_install $runtime_type $container_ip  $hostname "$uid" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && { 
        docker stop $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        rm -rf $log_dir
        error_exit 108 "runtime_install"
    }

    [[ "$disk_size" = "" || "$disk_size" -lt "512" || "$disk_size" -gt "10240" ]] && {
        disk_size=$RES_DISK_LIMIT
    }
    [ "$uid" != "" ] && { 
        setquota -u $uid $(($disk_size*1024)) $(($disk_size*1024)) $RES_INODE_LIMIT $RES_INODE_LIMIT $CONTAINER_DISK >>$LOGFILE 2>&1
        [ $? -ne 0 ] && {
            log "set disk quota failed"
        }
    }

    [ "$enable_swap" = "0" ] && {
        lxc-cgroup -n $long_id memory.memsw.limit_in_bytes $(($mem_size*1024*1024)) >> $LOGFILE 2>&1
    }

    ### cpu limit   
    lxc-cgroup -n $long_id cpu.cfs_quota_us $RES_CPU_CFS_QUOTA >> $LOGFILE 2>&1
    lxc-cgroup -n $long_id cpuset.cpus      "$RES_CPU_CPUSET" >> $LOGFILE 2>&1

    ### blkio limit
    lxc-cgroup -n $long_id blkio.throttle.write_iops_device "$CONTAINER_DISK_DEVNO $RES_BLKIO_WRITE_IOPS" >> $LOGFILE 2>&1
 
    ### network limit
    tc qdisc del dev $container_id root >> $LOGFILE 2>/dev/null
    tc qdisc add dev $container_id root handle 1: htb default 2 >> $LOGFILE 2>/dev/null
    tc class add dev $container_id parent 1: classid 1:1 htb rate $RES_NET_IN_RATE_ALL ceil $RES_NET_IN_CEIL_ALL >> $LOGFILE 2>/dev/null
    if [ "$bandwidth" != "" ]; then 
        tc class add dev $container_id parent 1:1 classid 1:2 htb rate ${bandwidth}mbps burst ${bandwidth}mb >> $LOGFILE 2>/dev/null
    else
        tc class add dev $container_id parent 1:1 classid 1:2 htb rate $RES_NET_IN_RATE_EXTERNAL burst $RES_NET_IN_BURST_EXTERNAL >> $LOGFILE 2>/dev/null
    fi 
    tc class add dev $container_id parent 1:1 classid 1:3 htb rate $RES_NET_IN_RATE_INTERNAL burst $RES_NET_IN_BURST_INTERNAL >> $LOGFILE 2>/dev/null
    tc filter add dev $container_id protocol ip parent 1:0 prio 1 u32 match ip src 172.17.42.1/32 flowid 1:3 >> $LOGFILE 2>/dev/null
    tc filter add dev $container_id protocol ip parent 1:0 prio 1 u32 match ip src 10.0.0.0/8 flowid 1:3 >> $LOGFILE 2>/dev/null

    tc qdisc del dev $container_id ingress >> $LOGFILE 2>/dev/null
    tc qdisc add dev $container_id ingress handle ffff: >> $LOGFILE 2>/dev/null
    tc filter add dev $container_id parent ffff: protocol ip prio 1 u32 match ip dst 172.17.42.1/32 police rate $RES_NET_OUT_RATE_INTERNAL burst $RES_NET_OUT_BURST_INTERNAL mtu 64kb drop flowid ffff:1 >> $LOGFILE 2>/dev/null
    tc filter add dev $container_id parent ffff: protocol ip prio 1 u32 match ip dst 10.0.0.0/8 police rate $RES_NET_OUT_RATE_INTERNAL burst $RES_NET_OUT_BURST_INTERNAL mtu 64kb drop flowid ffff:1 >> $LOGFILE 2>/dev/null
    if [ "$bandwidth" != "" ]; then
        tc filter add dev $container_id parent ffff: protocol ip prio 1 u32 match ip dst 0.0.0.0/0 police rate ${bandwidth}mbps burst ${bandwidth}mb mtu 64kb drop flowid ffff:2 >> $LOGFILE 2>/dev/null
    else
        tc filter add dev $container_id parent ffff: protocol ip prio 1 u32 match ip dst 0.0.0.0/0 police rate $RES_NET_OUT_RATE_EXTERNAL burst $RES_NET_OUT_BURST_EXTERNAL mtu 64kb drop flowid ffff:2 >> $LOGFILE 2>/dev/null
    fi

    echo $container_id $container_ip $long_id
    log ">>> instance_create end: $appid $runtime_type ($container_id $container_ip)"
}

function instance_delete()
{
    local instance_name=$1
    local container_id=$2
    local container_ip=$3
    local port_maps=$4
    local uid=$5
    local tcp_ports=$6
    local udp_ports=$7

    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    local log_dir=$LOG_ROOT/$instance_name

    log ">>> instance_delete begin: $container_id $container_ip $uid"

    ### enlarge memory size to ensure that we can delete container
    local long_id=$(docker inspect $container_id|grep "ID" |awk '{gsub(/[",]/, "", $2); print $2}')
    [ "$long_id" != "" ] && {
        local old_mem_size=$(lxc-cgroup -n $long_id memory.limit_in_bytes 2>/dev/null)
        [ -n "$old_mem_size" ] && {
            lxc-cgroup -n $long_id memory.memsw.limit_in_bytes $(($old_mem_size*5)) >/dev/null 2>&1
            lxc-cgroup -n $long_id memory.limit_in_bytes $(($old_mem_size*5)) >/dev/null 2>&1
        }
    }

    log "stop instance"
    $WSH --timeout $TO_WSH5 --socket $instance_dir/wshd.sock $LXCDO_SCRIPT instance_stop >>$LOGFILE 2>&1

    local init_pid=$(docker inspect $container_id |grep "Pid" |awk '{print $2}')

    log "stop container"
    docker stop -t=2 $container_id >> $LOGFILE 2>&1
    #docker wait $container_id >> $LOGFILE 2>&1
    log "remove container"
    docker rm $container_id >> $LOGFILE 2>&1

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
    find /sys/fs/cgroup/ -name "${container_id}*" |xargs -i find {} -depth -type d -print -exec rmdir {} \;
    find /sys/fs/cgroup/ -name "${container_id}*" |xargs rm -rf 

    ### check again
    docker ps -a |grep $container_id
    [ $? -eq 0 ] && {
        log "container still there, delete it again"
        docker rm $container_id >> $LOGFILE 2>&1
    }
    
    rm -rf $instance_dir
    rm -rf $log_dir

    ### delete iptables chain
    log "delete iptable rules"    
    for pair in $tcp_ports; do
        local p1=${pair%:*}
        local p2=${pair#*:}
		_del_port_rule "tcp" $p1 $p2 $container_id $container_ip
    done    

    for pair in $udp_ports; do
        local p1=${pair%:*}
        local p2=${pair#*:}
		_del_port_rule "udp" $p1 $p2 $container_id $container_ip
    done    

    log "delete quota"    
    ### delete quota at last
    [ "$uid" != "-1" ] && {
        setquota -u $uid 0 0 0 0 $CONTAINER_DISK >> $LOGFILE 2>&1
        #repquota -uv $CONTAINER_DISK |grep $uid
        #[ $? -eq 0 ] && {
        #    log "remove quota of $uid failed"
        #}
    }
    log ">>> instance_delete end: $container_id $container_ip"
}

function instance_restart()
{
    local instance_name=$1
    local container_id=$2
    local container_ip=$3
    LOGFILE=$LOG_DIR/${instance_name}.log
    
    local instance_dir=$INSTANCE_ROOT/$instance_name

    log ">>> instance_restart begin: $container_id $container_ip"
    $WSH --timeout $TO_WSH60 --socket $instance_dir/wshd.sock $LXCDO_SCRIPT instance_restart >>$LOGFILE 2>&1
    [ $? -ne 0 ] && { error_exit 100 "instance_restart"; }
    log ">>> instance_restart end: $container_id $container_ip"
}

function app_update()
{
    local instance_name=$1
    local info_file=$2
    source $info_file
    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    log ">>> app_update begin: $container_id $container_ip $appid"

    if [ "$app_location" != "" ]; then
        rm -rf $instance_dir/app
        cp -aR $app_location $instance_dir/app >> $LOGFILE 2>&1
        [ $? -ne 0 ] && {
            error_exit 100 "copy code from $app_location";
        }
    else
        local retry=0
        while :
        do
	    local index=$(($RANDOM%${#FILE_SERVERS[@]}))
	    local file_server=${FILE_SERVERS[$index]}
	    log "rsync code from fileserver $file_server ($retry)"
	    timeout $TO_RSYNC rsync -aq --partial --delete -e 'ssh -o "StrictHostKeyChecking=no" ' $FILE_SERVER_USER@$file_server:/home/bae/wwwdata/htdocs/$appid/ $instance_dir/app/ >>$LOGFILE 2>&1
	    [ $? -eq 0 ] && { break; }
	    retry=$(($retry+1))
	    [ $retry -eq 3 ] && {  error_exit 100 "rsync code from fileserver"; }
            sleep 1
        done
    fi

    local op_timeout=$TO_WSH60
    [ "$runtime_type" = "custom" ] && { op_timeout=$TO_WSH600; }
    log "pre app_update"
    $WSH --timeout $op_timeout --socket $instance_dir/wshd.sock $LXCDO_SCRIPT pre_app_update >>$LOGFILE 2>&1
    RET=$?
    [ $RET -ne 0 ] && { error_exit 101 "pre app_update ($RET)"; }

    log "app_update"
    $WSH --timeout $op_timeout --socket $instance_dir/wshd.sock $LXCDO_SCRIPT app_update $runtime_type >>$LOGFILE 2>&1
    RET=$?
    [ $RET -ne 0 ] && { error_exit 102 "app_update ($RET)"; }

    log "post app_update"
    $WSH --timeout $op_timeout --socket $instance_dir/wshd.sock $LXCDO_SCRIPT post_app_update >>$LOGFILE 2>&1
    RET=$?
    [ $RET -ne 0 ] && { error_exit 103 "post app_update ($RET)"; }
    log ">>> app_update end: $container_id $container_ip $appid"
}

function resource_update()
{
    local instance_name=$1
    local container_id=$2
    local uid=$3
    local mem_size=$4
    local disk_size=$5
    local enable_swap=$6
    local bandwidth=$7
    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    log ">>> resource_update begin: $container_id $uid $mem_size $disk_size"
  
    [ "$disk_size" != "" ] && { 
        repquota -uv $CONTAINER_DISK |grep "^#$uid"
        [ $? -ne 0 ] && {
            error_exit 100 "no such user"
        }

        [[ "$disk_size" -lt "512" || "$disk_size" -gt "10240" ]] && {
            error_exit 101 "invalid disk size"
        }

        setquota -u $uid $(($disk_size*1024)) $(($disk_size*1024)) 0 0 $CONTAINER_DISK >>$LOGFILE 2>&1
        [ $? -ne 0 ] && {
            error_exit 102 "set disk quota"
        }
    }

    [ "$mem_size" != "" ] && {
        local long_id=$(docker inspect $container_id|grep "ID" |awk '{gsub(/[",]/, "", $2); print $2}')
        [ "$long_id" = "" ] && {
            error_exit 103 "invalid long id"
        }

        [[ "$mem_size" -lt "64" || "$mem_size" -gt "2048" ]] && {
            error_exit 104 "invalid mem size"
        }

        local new_mem_size=$(($mem_size*1024*1024))
        local old_mem_size=$(lxc-cgroup -n $long_id memory.limit_in_bytes 2>/dev/null)
        local new_memsw_size=$new_mem_size
        if [ "$enable_swap" = "1" ]; then
            new_memsw_size=$(($new_mem_size*2))
        fi

        if [ -n "$old_mem_size" -a $((new_memsw_size-old_mem_size)) -gt 0 ]; then
            lxc-cgroup -n $long_id memory.memsw.limit_in_bytes $new_memsw_size >> $LOGFILE 2>&1
            [ $? -ne 0 ] && { error_exit 106 "set memory+swap limit"; }
            lxc-cgroup -n $long_id memory.limit_in_bytes $new_mem_size >> $LOGFILE 2>&1
            [ $? -ne 0 ] && { error_exit 105 "set memory limit"; }
        else
            lxc-cgroup -n $long_id memory.limit_in_bytes $new_mem_size >> $LOGFILE 2>&1
            [ $? -ne 0 ] && { error_exit 105 "set memory limit"; }
            lxc-cgroup -n $long_id memory.memsw.limit_in_bytes $new_memsw_size >> $LOGFILE 2>&1
            [ $? -ne 0 ] && { error_exit 106 "set memory+swap limit"; }
        fi

        echo "MEMORY_SIZE $mem_size" > $instance_dir/resource.info
        $WSH --timeout $TO_WSH60 --socket $instance_dir/wshd.sock $LXCDO_SCRIPT resource_update >>$LOGFILE 2>&1
    }

    [ "$bandwidth" != "" ] && {
        tc class replace dev $container_id parent 1:1 classid 1:2 htb rate ${bandwidth}mbps burst ${bandwidth}mb >>$LOGFILE 2>&1
        [ $? -ne 0 ] && { error_exit 115 "set in-bandwidth"; }
        tc filter replace dev $container_id parent ffff: protocol ip handle 800::802 prio 1 u32 match ip dst 0.0.0.0/0 police rate ${bandwidth}mbps burst ${bandwidth}mb mtu 64kb drop flowid ffff:2 >>$LOGFILE 2>&1
        [ $? -ne 0 ] && { error_exit 115 "set out-bandwidth"; }
    }

    log ">>> resource_update end: $container_id"
}

function port_update()
{
    local instance_name=$1
    local container_id=$2
    local container_ip=$3
    local del_tcp_ports=$4
    local add_tcp_ports=$5
    local del_udp_ports=$6
    local add_udp_ports=$7
    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    log ">>> port_update begin: $container_id $container_ip" 

    local result=0
    for pair in $del_tcp_ports; do
        local p1=${pair%:*}
        local p2=${pair#*:}
		_del_port_rule "tcp" $p1 $p2 $container_id $container_ip
		[ $? -ne 0 ] && { $result=1; }
    done

    for pair in $add_tcp_ports; do
        local p1=${pair%:*}
        local p2=${pair#*:}
		_add_port_rule "tcp" $p1 $p2 $container_id $container_ip	
		[ $? -ne 0 ] && { $result=1; }
	done

    for pair in $del_udp_ports; do
        local p1=${pair%:*}
        local p2=${pair#*:}
		_del_port_rule "udp" $p1 $p2 $container_id $container_ip
		[ $? -ne 0 ] && { $result=1; }
    done

    for pair in $add_udp_ports; do
        local p1=${pair%:*}
        local p2=${pair#*:}
		_add_port_rule "udp" $p1 $p2 $container_id $container_ip	
		[ $? -ne 0 ] && { $result=1; }
    done

    log ">>> port_update end: $container_id $container_ip"
    exit $result
}

function addon_start()
{
    local instance_name=$1
    local addon_name=$2
    local conf_list="$3"
    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    log ">>> addon_start begin: $instance_name $addon_name"
    $WSH --socket $instance_dir/wshd.sock $LXCDO_SCRIPT addon_start $addon_name "$conf_list" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && {
        error_exit 100 "addon_start"
    }
    log ">>> addon_start end: $instance_name $addon_name"
}

function addon_stop()
{
    local instance_name=$1
    local addon_name=$2
    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    log ">>> addon_stop begin: $instance_name $addon_name"
    $WSH --socket $instance_dir/wshd.sock $LXCDO_SCRIPT addon_stop $addon_name >>$LOGFILE 2>&1
    [ $? -ne 0 ] && {
        error_exit 100 "addon_stop"
    }
    log ">>> addon_stop end: $instance_name $addon_name"
}

function firewall_setup()
{
    local item_list=$1

    current_rules=$(iptables-save |grep hades_rule)
    while read rule
    do
        [ ${#rule} -lt 10 ] && { continue; }
        log "deleting old rule ($rule)"
        iptables -t filter -D ${rule:3}
    done <<< "$current_rules"
    
    IFS_BAK="$IFS"
    IFS="&"; for item in $item_list
    do
        echo "$item" | grep "^*" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            item=${item#"*"}
            iptables_rule="$item"
        else
            IFS=: read proto ip mask port <<< "$item"
            [ "$ip" = "" ] && { log "invalid rule: ($item)"; continue; }
            [ "$mask" = "" ] && { mask="32"; }
            [ "$proto" != "" ] && { proto="-p $proto -m $proto"; }
            [ "$port" != "" ] && { port="--dport $port"; }
            iptables_rule="iptables -t filter -I FORWARD -d $ip/$mask -o eth1 $proto $port -j ACCEPT"
        fi

        iptables_rule="$iptables_rule -m comment --comment \"hades_rule\""
        local retry=0
        while :
        do
            #echo "iptables -t filter -I FORWARD -d $ip/$mask -o eth1 $proto $port -j ACCEPT -m comment --comment \"hades_rule\""
            eval "$iptables_rule"
            [ $? -eq 0 ] && { break; }
            retry=$(($retry+1))
            [ $retry -eq 3 ] && {
                log "add rule failed: ($item)"
                break
            }
            sleep 1
        done
    done
    IFS="$IFS_BAK"
}

function exec_command()
{
    local cmd="$1"
    log ">>> exec_command begin: ($cmd)"
    eval "$cmd >> $LOGFILE 2>&1"
    local ret=$?
    [ $ret -ne 0 ] && { error_exit $ret "failed"; } 
    log ">>> exec_command end: ($cmd)"
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

