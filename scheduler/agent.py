import time
import os 
import sys
import signal
import logging
import logging.handlers

deps_dir = os.environ['AGENT_DIR'] + "/deps/lib/python2.7/site-packages/"
if sys.path[0] != deps_dir:
    sys.path.insert(0, deps_dir)

import consumer
from agent import module

def setup_logger(logtype):
    logger = logging.getLogger()
    if logtype == "stdout":
        h = logging.StreamHandler()
    else:
        h = logging.handlers.TimedRotatingFileHandler(
                os.environ['LOG_FILE'],
                when='midnight', 
                interval=1,
                backupCount=30)
    f = logging.Formatter('%(asctime)s %(levelname)-8s %(message)s')
    h.setFormatter(f)
    logger.addHandler(h)
    logger.setLevel(logging.NOTSET)

def try_lock():
    import fcntl
    lockfile = os.open(os.environ['LOCK_FILE'], os.O_RDWR|os.O_CREAT)
    try:
        fcntl.flock(lockfile, fcntl.LOCK_EX|fcntl.LOCK_NB)
        os.write(lockfile, str(os.getpid()))
        return True
    except:
        try:
            pid = os.read(lockfile, 1024)
            print "oops: another agent (%s) is in running status" % pid
        except: pass
        return False

def daemonize():
    if 0 != os.fork(): sys.exit(0)
    if 0 != os.fork(): sys.exit(0)

g_running_flag = False
def signal_handler(signum, frame):
    global g_running_flag 
    g_running_flag = False 

def main_loop():
    import getopt
    try:
        opts, args = getopt.getopt(sys.argv[1:], ":d")
    except getopt.GetoptError, e:
        print str(e)
        sys.exit(2)

    if not try_lock():
        print "try lock failed"
        sys.exit(3)
        
    daemon = False
    for o, v in opts:
        if o == '-d':
            daemon = True
        else:
            print "Unkown options: %s" % o
    
    if daemon:  daemonize()
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    setup_logger(os.environ['LOG_TYPE'])

    if not module.init():
        logging.warning("handlers init failed")
        sys.exit(4)
 
    cm = consumer.Consumer(
        os.environ['RABBITMQ_SERVER_LIST'],
        os.environ['SCHEDULER_VHOST'], 
        os.environ['RABBITMQ_USER'],
        os.environ['RABBITMQ_PASS'],
        os.environ['SCHEDULER_EXCHANGE_NAME'],
        os.environ['THIS_AGENT_NAME'],
        int(os.environ['WORKER_NUM']))

    cm.start()
    time.sleep(1)    
  
    global g_running_flag 
    g_running_flag = True

    logging.info("enter mainloop")
    while g_running_flag:
        time.sleep(1)

    logging.info("quit mainloop")
    cm.stop()
    cm.wait()

    module.fini()
    logging.info("thread main: exit")

main_loop()

