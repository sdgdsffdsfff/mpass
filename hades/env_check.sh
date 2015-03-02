source conf.sh

if [ $(id -u) -ne 0 ]; then
    echo "user must be root"
    exit 1
fi

#ps ax |grep "agent.py -d" |grep -v "grep agent.py"
#[ $? -eq 0 ] && {
#	echo "another hades is in running status"
#	exit 1
#}

ps auxf |grep "docker" |grep -v "grep" >/dev/null
[ $? -ne 0 ] && {
    echo "docker server not running"
    exit 1
}

[ "${THIS_HOST:0:4}" = "127." ] && {
    echo "invalid host ip"
    exit 1
}

[ ! -d $DOCKER_DIR ] && {
    echo "missing docker $DOCKER_DIR"
    exit 1
}

[ ! -L /usr/local/bin/nsenter ] && {
	cp -f tools/nsenter /usr/local/bin/
	cp -f tools/docker-enter.sh /usr/local/bin/
}

for dir in cpu cpuset memory blkio
do 
    [ ! -d "/cgroup/$dir" ] && {
        echo "missing cgroup $dir"
        exit 1
    }
done

for server in $RABBITMQ_SERVER_LIST
do
    host=${server%:*}
    ping -c 2 $host >/dev/null
    [ $? -ne 0 ] && {
        echo "cloudn't ping rabbitmq server: $host"
        exit 1
    }
done

exit 0

