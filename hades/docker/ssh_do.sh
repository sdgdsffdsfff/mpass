#!/bin/bash

##set +x

source /home/bae/baeng/hades/conf.sh

HOST_SHARE_ROOT=/home/bae/share
GUEST_SHARE_ROOT=/home/admin/share
IMAGE_ROOT=$HOST_SHARE_ROOT/imagecaches
INSTANCE_ROOT=$HOST_SHARE_ROOT/instances
LOG_ROOT=$HOST_SHARE_ROOT/logs
LXCDO_SCRIPT=$GUEST_SHARE_ROOT/instance/do.sh

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
    local type=$1
    [[ "$type" == "php-web" || "$type" == "php-worker" ]] && {
        echo $DOCKER_PHP_IMAGE_ID
        return 0
    }   
    [[ "$type" == "java-web" ]] && {
        echo $DOCKER_JAVA_IMAGE_ID
        return 0
    }
    [[ "$type" == "python-web" || "$type" == "python-worker" ]] && {
        echo $DOCKER_PYTHON_IMAGE_ID
        return 0
    }   
    echo $DOCKER_BASE_IMAGE_ID
}

function runtime_install()
{
    local runtime_type=$1
    local image_location=$2
    local image_md5=$3

    log ">>> runtime_install begin: $runtime_type $image_location $image_md5"
    [ "$image_md5" != "" ] && {
        [ -d $IMAGE_ROOT/$runtime_type ] && {
            [ -L $IMAGE_ROOT/$runtime_type ] && {
                local tmp=$(readlink $IMAGE_ROOT/$runtime_type)
                [ $? -eq 0 ] && {
                    local local_md5=$(basename $tmp)
                    [ "$image_md5" = "$local_md5" ] && {
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
        image_file=$WORK_DIR/${runtime_type}.${now}
        log "wget -q $image_location -O $image_file"
        wget -q $image_location -O $image_file 
        [ $? -ne 0 ] && { error_exit 2 "download $image_location failed"; }
    else
        error_exit 1 "invalid proto $proto"
    fi

    local new_md5=$(md5sum $image_file |awk '{print $1}')
    local image_dir=$IMAGE_ROOT/$runtime_type.images/$new_md5
    rm -rf $image_dir
    mkdir -p $image_dir
    tar xzf $image_file -C $image_dir
    [ $? -ne 0 ] && {
        [ "$proto" = "http" ] && { rm -f $image_file; }
        error_exit 3 "uncompress image file $image_file failed"
    }

    chown bae:bae $image_dir -R
    rm -rf $IMAGE_ROOT/$runtime_type
    ln -sf $runtime_type.images/$new_md5 $IMAGE_ROOT/$runtime_type >>$LOGFILE 2>&1
    [ $? -ne 0 ] && {
        [ "$proto" = "http" ] && { rm -f $image_file; }
        error_exit 4 "ln -sf $image_dir $IMAGE_ROOT/$runtime_type failed"
    }
    log ">>> runtime_install end: $runtime_type $image_location $image_md5"
}

function instance_create()
{
    local instance_name=$1
    local appid="$2"
    local runtime_type=$3
    local env_list="$4"
    local port_maps="$5"
    local uid=$6

    LOGFILE=$LOG_DIR/${instance_name}.log

    log ">>> instance_create begin: $appid $runtime_type $uid"

    [ ! -L $IMAGE_ROOT/$runtime_type ] && { error_exit 100 "$runtime_type must be symbolic link"; }  
    #[ ! -f /root/.ssh/id_rsa.pub ] && { error_exit 100 "missing id_rsa.pub"; }

    local instance_dir=$INSTANCE_ROOT/$instance_name
    mkdir -p $instance_dir
    rm -rf $instance_dir/*

    local log_dir=$LOG_ROOT/$instance_name
    mkdir -p $log_dir
    rm -rf $log_dir/*
 
    #cp -f /root/.ssh/id_rsa.pub  $instance_dir/

    local port_opts=""
    for pair in $port_maps; do
        pair=$(echo $pair|sed 's/=/:/')
        port_opts="$port_opts -p $pair"
    done

    local dns_opts=""
    for dns in $DOCKER_DNS_SERVERS; do
        dns_opts="$dns_opts -dns=$dns"
    done

    local image_id=$(_get_container_image_id $runtime_type)

    local container_id=$(docker run \
        -d \
        -v $HOST_SHARE_ROOT/ssh:/root/.ssh \
        -v $IMAGE_ROOT:$GUEST_SHARE_ROOT/imagecaches:ro \
        -v $instance_dir:$GUEST_SHARE_ROOT/instance \
        -v $log_dir:/home/bae/log \
        -h $instance_name \
        -m $(($DOCKER_MEM_LIMIT * 1024 * 1024)) \
        $port_opts \
        $dns_opts \
        $image_id /usr/sbin/sshd -D 2>>$LOGFILE
    )
    #$image_id /bin/bash -c "/usr/sbin/baeinit ; /usr/sbin/sshd -D" 2>>$LOGFILE
    [ $? -ne 0 ] && { 
        rm -rf $instance_dir
        error_exit 101 "create container";
    }
    log "container_id: ($container_id)"
    [ "$container_id" == "" ] && {
        rm -rf $instance_dir
        error_exit 102 "invalid container id"
    }
    docker inspect $container_id |grep '"Running": true' >> $LOGFILE 2>&1
    [ $? -ne 0 ] && {
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 103 "container not in running state"
    }
    local long_id=$(docker inspect $container_id|grep "ID" |awk '{gsub(/[",]/, "", $2); print $2}')
    [ $? -ne 0 ] && {
        #docker stop -t=1 $container_id >> $LOGFILE 2>&1
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 104 "missing container long id"
    }
    local container_dir=$DOCKER_ROOT_DIR/containers/$long_id
    [ ! -d $container_dir ] && { 
        #docker stop -t=1 $container_id >> $LOGFILE 2>&1
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 105 "missing container directory"; 
    }

    local container_ip=$(docker inspect $container_id|grep "IPAddress" |awk '{gsub(/[",]/, "", $2); print $2}')
    [[ $? -ne 0 || "$container_ip" = "" ]] && { 
        #docker stop -t=1 $container_id >> $LOGFILE 2>&1
        docker stop  $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 106 "no container IP";
    }
    log "$container_id $container_ip" 
    ssh-keygen -f "/root/.ssh/known_hosts" -R $container_ip >>$LOGFILE 2>&1

    local retry=0
    while :
    do
        local index=$(($RANDOM%${#FILE_SERVERS[@]}))
        local file_server=${FILE_SERVERS[$index]}
        log "rsync code from fileserver $file_server"
        rsync -aPtq --delete -e 'ssh -o "StrictHostKeyChecking=no" ' $FILE_SERVER_USER@$file_server:/home/bae/wwwdata/htdocs/$appid/ $instance_dir/app/ >>$LOGFILE 2>&1
        [ $? -eq 0 ] && { break; }
        retry=$(($retry+1))
        [ $retry -eq 3 ] && {
            #docker stop -t=1 $container_id >> $LOGFILE 2>&1
            docker stop $container_id >> $LOGFILE 2>&1
            docker wait $container_id >> $LOGFILE 2>&1
            docker rm $container_id >> $LOGFILE 2>&1
            rm -rf $instance_dir
            error_exit 107 "rsync code from fileserver"; 
        }
        sleep 1
    done

    #log "generate environment file"
    #local user_profile=$instance_dir/profile
    #touch $user_profile
    #for x in $env_list
    #do
    #    echo "export $x" >> $user_profile
    #done

    cp -f /home/bae/baeng/hades/docker/lxcdo.sh $instance_dir/do.sh 

    log "runtime_install"
    ssh $SSH_OPTS root@$container_ip "$LXCDO_SCRIPT runtime_install $runtime_type "$uid"" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && { 
        #docker stop -t=1 $container_id >> $LOGFILE 2>&1
        docker stop $container_id >> $LOGFILE 2>&1
        docker wait $container_id >> $LOGFILE 2>&1
        docker rm $container_id >> $LOGFILE 2>&1
        rm -rf $instance_dir
        error_exit 108 "runtime_install"; 
    }

    [ "$uid" != "" ] && { 
        setquota -u $uid $(($DOCKER_DISK_LIMIT*1024)) $(($DOCKER_DISK_LIMIT*1024)) 0 0 $CONTAINER_DISK >>$LOGFILE 2>&1
        [ $? -ne 0 ] && {
            log "set disk quota failed"
        }
    }

    #tc qdisc del dev $container_id root >>$LOGFILE 2>/dev/null
    #tc qdisc del dev $container_id ingress >>$LOGFILE 2>/dev/null
    #tc qdisc add dev $container_id root tbf rate $DOCKER_NET_IN_RATE burst $DOCKER_NET_IN_BURST latency $DOCKER_NET_IN_LATENCY >> $LOGFILE 2>&1
    #[ $? -ne 0 ] && {
    #    log "set qdisc failed"
    #}
    #tc qdisc add dev ${network_host_iface} ingress handle ffff:
    echo $container_id $container_ip
    log ">>> instance_create end: $appid $runtime_type ($container_id $container_ip)"
}

function instance_delete()
{
    local instance_name=$1
    local container_id=$2
    local container_ip=$3
    local port_maps=$4
    local uid=$5
    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    local log_dir=$LOG_ROOT/$instance_name

    log ">>> instance_delete begin: $container_id $container_ip $uid"
    ssh $SSH_OPTS root@$container_ip "$LXCDO_SCRIPT instance_stop" >>$LOGFILE 2>&1

    local init_pid=$(docker inspect $container_id |grep "Pid" |awk '{print $2}')

    docker stop -t=2 $container_id >> $LOGFILE 2>&1
    #docker wait $container_id >> $LOGFILE 2>&1
    docker rm $container_id >> $LOGFILE 2>&1

    pid=$(ps aux|grep "lxc-start -n $container_id"|grep -v "grep" |awk '{print $2}')
    [ "$pid" != "" ] && {
        log "kill container pid: $pid"
        kill -9 $pid
    }
    [ "$init_pid" != "" ] && {
        init_pid=${init_pid%*,}
        [ "$init_pid" != "0" ] && {
            log "kill init pid: $init_pid"
            kill -9 $init_pid
        }
    }

    [ -d $DOCKER_ROOT_DIR/containers/${container_id}* ] && { 
        #fuser -k -m /data/docker/containers/${container_id}*/rootfs
        #fuser -k -m /data/docker/containers/${container_id}*/rw
        umount $DOCKER_ROOT_DIR/containers/${container_id}*/rootfs
        rm -rf $DOCKER_ROOT_DIR/containers/${container_id}*
        [ $? -ne 0 ] && {
            log "remove container dir failed"
        }
    }

    ### delete network device
    ip link del $container_id
    /sbin/ifconfig -a |grep $container_id
    [ $? -eq 0 ] && {
        log "delete network device failed"
    }

    ### delete cgroup entries
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
    ssh-keygen -f "/root/.ssh/known_hosts" -R $container_ip >> $LOGFILE 2>&1

    ### delete quota at last
    [ "$uid" != "-1" ] && {
        setquota -u $uid 0 0 0 0 $CONTAINER_DISK >> $LOGFILE 2>&1
        repquota -uv $CONTAINER_DISK |grep $uid
        [ $? -eq 0 ] && {
            log "remove quota of $uid failed"
        }
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
    ssh $SSH_OPTS root@$container_ip "$LXCDO_SCRIPT instance_restart" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && { error_exit 100 "instance_restart"; }
    log ">>> instance_restart end: $container_id $container_ip"
}

function app_update()
{
    local instance_name=$1
    local container_id=$2
    local container_ip=$3
    local appid=$4
    LOGFILE=$LOG_DIR/${instance_name}.log

    local instance_dir=$INSTANCE_ROOT/$instance_name
    log ">>> app_update begin: $container_id $container_ip $appid"

    local retry=0
    while :
    do
        local index=$(($RANDOM%${#FILE_SERVERS[@]}))
        local file_server=${FILE_SERVERS[$index]}
        log "rsync code from fileserver $file_server"
        rsync -aPtq --delete -e 'ssh -o "StrictHostKeyChecking=no" ' $FILE_SERVER_USER@$file_server:/home/bae/wwwdata/htdocs/$appid/ $instance_dir/app/ >>$LOGFILE 2>&1
        [ $? -eq 0 ] && { break; }
        retry=$(($retry+1))
        [ $retry -eq 3 ] && {  error_exit 100 "rsync code from fileserver"; }
        sleep 1
    done

    log "pre app_update"
    ssh $SSH_OPTS root@$container_ip "$LXCDO_SCRIPT pre_app_update" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && { error_exit 101 "pre app_update"; }

    log "rsync code into container"
    #rsync -aPtq --delete -e 'ssh -o "StrictHostKeyChecking=no" '  $instance_dir/app/ root@$container_ip:/home/bae/app/ >>$LOGFILE 2>&1
    ssh $SSH_OPTS root@$container_ip "$LXCDO_SCRIPT app_update" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && { error_exit 102 "rsync code into container"; }

    log "post app_update"
    ssh $SSH_OPTS root@$container_ip "$LXCDO_SCRIPT post_app_update" >>$LOGFILE 2>&1
    [ $? -ne 0 ] && { error_exit 103 "post app_update"; }
    log ">>> app_update end: $container_id $container_ip $appid"
}

function active_container_list()
{
    docker ps -q
    [ $? -eq 0 ] && { exit 0; }
    ### docker server not in running state, use ps
    ps aux |grep "lxc-start -n" |grep -v "grep" |awk '{print $13}' |cut -c -12
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
    local x0=$(($mem_size/$DOCKER_MEM_LIMIT))
    disk_size=${disk_size:0:-1}
    local x1=$(($disk_size/$DOCKER_DISK_LIMIT))
    [ $x0 -lt $x1 ] && { echo $x0; } || { echo $x1; }
}

FUNC=$1
shift

$FUNC "$@"
exit 0

