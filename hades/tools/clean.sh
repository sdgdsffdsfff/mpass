container_id=$1
uid=$2

source /home/bae/baeng/hades/conf.sh
XDIR=$DOCKER_DIR/containers

[ ${#container_id} -lt 12 ] && { echo "length of container id must >= 12"; exit 1; }
[ ${#container_id} -gt 12 ] && { container_id=$(echo $container_id |cut -c 1-12 ); }

echo "container_id: ($container_id)"

### killl running lxc-start
init_pid=$(docker inspect $container_id |grep "Pid" |awk '{print $2}')

docker stop -t=1  $container_id  2>/dev/null
docker rm $container_id 2>/dev/null

pid=$(ps aux|grep "lxc-start -n $container_id"|grep -v "grep" |awk '{print $2}')
[ "$pid" != "" ] && {
   echo "kill container pid: $pid"
   kill -9 $pid 2>/dev/null
}

[ -d /sys/fs/cgroup/memory/lxc/${container_id}* ] && {
    tasks=$(cat /sys/fs/cgroup/memory/lxc/${container_id}*/tasks)
    [ $? -eq 0 ] && {
        echo "still has running process"
        for pid in $tasks
        do 
            kill -9 $pid 2>/dev/null
        done
    }
}

[ "$init_pid" != "" ] && {
    init_pid=${init_pid%*,}
    [ "$init_pid" != "0" ] && {
        echo "kill init pid: $init_pid"
        kill -9 $init_pid 2>/dev/null
    }
}

[ -d $XDIR/${container_id}* ] && {
   echo "delete contaienr dir"
   umount $XDIR/${container_id}*/rootfs 2>/dev/null
   rm -rf $XDIR/${container_id}*
   [ $? -ne 0 ] && {
       echo "remove container dir failed"
       exit 1
   }
}

echo "delete network device"
ip link del $container_id 2>/dev/null
/sbin/ifconfig -a |grep $container_id
[ $? -eq 0 ] && {
   echo "delete network device failed"
   exit 1
}

echo "remove cgroups"
find /sys/fs/cgroup/ -name "${container_id}*" |xargs -i find {} -depth -type d -print -exec rmdir {} \;
find /sys/fs/cgroup/ -name "${container_id}*" |xargs rm -rf

[ "$uid" != "" ] && {
   setquota -u $uid 0 0 0 0 $CONTAINER_DISK
   repquota -uv $CONTAINER_DISK |grep $uid
   [ $? -ne 0 ] && {
       echo "remove quota failed"
       exit 1
   }
}

docker ps -a |grep $container_id
[ $? -eq 0 ] && {
    echo "container still there, delete it again"
    docker rm $container_id 2>/dev/null
}

echo "finished"

