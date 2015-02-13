import os
import cPickle
import threading
import Queue
import fcntl
import time
import logging
import logging.handlers

DELAY = 15
STATUS_FILE = "/home/bae/run/baeng/hades/status/instance.status"
RUNTIME_STATUS_FILE = "/home/bae/run/baeng/hades/status/runtime.status"
LOG = logging.getLogger(__name__)
handler = logging.handlers.TimedRotatingFileHandler("/home/bae/logs/baeng/hades/runtime_check.log", "D", 1, 7)
handler.suffix = "%Y%m%d"
LOG.setLevel(logging.DEBUG)
LOG.addHandler(handler)

q = Queue.Queue()
lock = threading.Lock()
workers = 15
bad_runtimes = []

def runtime_check(instance):
    """
    error_map: http://wiki.babel.baidu.com/twiki/bin/view/Com/CloudOS/SchedulerService
    """
    try:
        ret = os.system("timeout 2 /usr/local/bin/wsh --socket /home/bae/share/instances/%s/wshd.sock bash -c \"if [ ! -e /home/admin/share/.lxcdo ]; then /home/admin/runtime/check.sh >/dev/null 2>&1; else exit 0; fi\""%instance)
        if ret > 255:
            real_ret = hex(ret)
            errno, signo = int(real_ret[:-2], 16), int(real_ret[-2:], 16) 
            LOG.warning("%s %s"%(errno, instance))
            flag = 201 if errno == 124 else errno
            lock.acquire()    
            bad_runtimes.append((instance, flag))
            lock.release()
    except:
        pass

def checking():
    while 1:
        instance = q.get()
        runtime_check(instance)
        q.task_done()
   
for i in range(workers):
    t = threading.Thread(target=checking)
    t.setDaemon(True)
    t.start()

def loop():
    def load_from_disk():
        try:
            with open(STATUS_FILE, "rb") as f:
                a = cPickle.load(f)
                return True, a
                """
                for k, v in a.items():
                    print "============================"
                    print k
                    print v['container_id']
                    print v['container_ip']
                    print v['instance_id']
                    print v['appid']
                    print v['app_type']
                """
        except Exception, e:
            return False, None
    
    ret, status_info = load_from_disk()
    if not ret:
        LOG.warning("failed to load instance.status")
        return None
    instance_list = [k for k,v in status_info.items()]
    
    map(q.put, instance_list)            
    q.join()
    
    global bad_runtimes
    
    try:
        with open(RUNTIME_STATUS_FILE, "wb") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            cPickle.dump(bad_runtimes, f, cPickle.HIGHEST_PROTOCOL)
            fcntl.flock(f, fcntl.LOCK_UN)
    except Exception, e:
        LOG.warning("failed to generate runtime.status (%s)"%e)
    
    bad_runtimes = [] 
  
while 1:
    loop()
    time.sleep(DELAY)
