# all paths must be absolute

AGENT_NAME=scheduler
PYTHON_BIN=python2.6

export AGENT_DIR=/letv/mpass/$AGENT_NAME
export LOG_DIR=/letv/logs/mpass/$AGENT_NAME/
export WORK_DIR=/letv/run/mpass/$AGENT_NAME/work
export STATUS_DIR=/letv/run/mpass/$AGENT_NAME/status

export LOG_FILE=$LOG_DIR/agent.log
export LOG_TYPE="file"

## running mode: rdtest, qatest, product
RUNMODE="product"
source $AGENT_DIR/conf/${RUNMODE}.conf.sh

