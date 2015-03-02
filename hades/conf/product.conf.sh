export DEBUG_MODE=0
export HEALTHY_CHECK=1
export WORKER_NUM=5

export RABBITMQ_SERVER_LIST="10.176.28.145:5672"
export RABBITMQ_USER="hades_agent"
export RABBITMQ_PASS="hades_agent"

export SCHEDULER_VHOST="/hades"
export SCHEDULER_EXCHANGE_NAME="command.exchange"
export SCHEDULER_HEARTBEAT_QUEUE="heartbeat.queue"
export THIS_AGENT_NAME="hades@$THIS_HOST"

export DOCKER_DIR=/letv/docker
export DOCKER_MAX_INSTANCE_COUNT=10

export CONTAINER_DISK=/letv
export CONTAINER_DNS_SERVERS="10.50.140.13 10.50.144.14"

