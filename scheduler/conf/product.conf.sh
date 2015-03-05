export DEBUG_MODE=0
export HEALTHY_CHECK=1
export WORKER_NUM=5

export RABBITMQ_SERVER_LIST="10.176.28.145:5672"
export RABBITMQ_USER="hades_agent"
export RABBITMQ_PASS="hades_agent"

export SCHEDULER_VHOST="/hades"
export SCHEDULER_EXCHANGE_NAME="command.exchange"
export SCHEDULER_HEARTBEAT_QUEUE="heartbeat.queue"
export THIS_AGENT_NAME="scheduler@$THIS_HOST"

