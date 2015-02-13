export DEBUG_MODE=0
export HEALTHY_CHECK=1
export WORKER_NUM=15

export RABBITMQ_SERVER_LIST="10.81.64.109:5672 10.81.64.109:5672"
export RABBITMQ_USER="guest"
export RABBITMQ_PASS="guest"

export SCHEDULER_VHOST="/scheduler"
export SCHEDULER_EXCHANGE_NAME="hades_request.exchange"
export SCHEDULER_HEARTBEAT_QUEUE="hades_reply.queue"
export THIS_AGENT_NAME="hades@$THIS_HOST"

export FILE_SERVER_USER=bae
export FILE_SERVERS=("10.81.64.109" "10.81.64.109" "10.81.64.109")

export DOCKER_ROOT_DIR="/home/bae/docker"
export DOCKER_MAX_INSTANCE_COUNT=200

export CONTAINER_DISK="/home"
export CONTAINER_DNS_SERVERS=""

