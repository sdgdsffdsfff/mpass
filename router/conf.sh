# all paths must be absolute

### your agent name
AGENT_NAME=router

PYTHON_BIN=python2.6

export AGENT_DIR=/letv/mpass/$AGENT_NAME
export LOG_DIR=/letv/logs/mpass/$AGENT_NAME
export RUN_DIR=/letv/run/mpass/$AGENT_NAME

export LOG_FILE=$LOG_DIR/agent.log
export WORK_DIR=$RUN_DIR/work
export STATUS_DIR=$RUN_DIR/status
export LOCK_FILE=$RUN_DIR/agent.lock
export LOG_TYPE="file"

export THIS_HOST=10.154.156.122

## running mode: rdtest, qatest, product
RUNMODE="product"
source $AGENT_DIR/conf/${RUNMODE}.conf.sh

