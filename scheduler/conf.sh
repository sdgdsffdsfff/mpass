# all paths must be absolute

AGENT_NAME=scheduler
PYTHON_BIN=python2.6

export AGENT_DIR=/letv/mpass/$AGENT_NAME
export LOG_DIR=/letv/logs/mpass/$AGENT_NAME/
export RUN_DIR=/letv/run/mpass/$AGENT_NAME

export WORK_DIR=$RUN_DIR/work
export STATUS_DIR=$RUN_DIR/status

export LOG_FILE=$LOG_DIR/agent.log
export LOCK_FILE=$RUN_DIR/agent.lock
export LOG_TYPE="file"

export THIS_HOST=$(grep IPADDR /etc/sysconfig/network-scripts/ifcfg-eth0 | awk 'BEGIN{FS="="} {print $2}')

## running mode: rdtest, qatest, product
RUNMODE="product"
source $AGENT_DIR/conf/${RUNMODE}.conf.sh

