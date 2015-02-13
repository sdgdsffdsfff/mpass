# all paths must be absolute

AGENT_NAME=hades
PYTHON_BIN=python2.6

export AGENT_DIR=/letv/hades
export LOG_DIR=/letv/logs/$AGENT_NAME/
export WORK_DIR=/letv/run/hades/work
export STATUS_DIR=/letv/run/baeng/status
export DOCKER_DIR=/srv/docker

export LOG_FILE=$LOG_DIR/agent.log
export LOCK_FILE=/letv/run/hades/hades.lock
export LOG_TYPE="file"

export THIS_HOST=10.154.156.122
export DOCKER0_IP=$(/sbin/ifconfig docker0 | grep "inet addr" | awk '{print $2}' | sed 's/addr://g')

## running mode: rdtest, qatest, product
RUNMODE="product"
source $AGENT_DIR/conf/${RUNMODE}.conf.sh

### memory limit /MB
export RES_MEM_LIMIT=256
export RES_SWAP_LIMIT=""

### disk limit /MB
export RES_DISK_LIMIT=2048
export RES_INODE_LIMIT=200000

### cpu limit
CPU_NUM=$(grep processor /proc/cpuinfo | wc -l)
export RES_CPU_CPUSET="1-$((CPU_NUM-1))"
export RES_CPU_CFS_QUOTA=100000

### blkio limit
export CONTAINER_DISK_DEVNO="8:0"
export RES_BLKIO_READ_BPS=
export RES_BLKIO_WRITE_BPS=
export RES_BLKIO_READ_IOPS=
export RES_BLKIO_WRITE_IOPS=60

### network in
export RES_NET_IN_RATE_ALL=20mbps
export RES_NET_IN_CEIL_ALL=20mbps
export RES_NET_IN_RATE_INTERNAL=15mbps
export RES_NET_IN_BURST_INTERNAL=15mb
export RES_NET_IN_RATE_EXTERNAL=5mbps
export RES_NET_IN_BURST_EXTERNAL=5mb
### network out
export RES_NET_OUT_RATE_INTERNAL=15mbps
export RES_NET_OUT_BURST_INTERNAL=15mb
export RES_NET_OUT_RATE_EXTERNAL=5mbps
export RES_NET_OUT_BURST_EXTERNAL=5mb

