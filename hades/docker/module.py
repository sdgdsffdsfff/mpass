import os
import logging
import subprocess
import threading
import datetime
import time
import json
import urllib2 
import cPickle

from instance_manager  import InstanceManager
import util
import global_context

DO_SCRIPT = os.environ["AGENT_DIR"] + "/docker/do.sh"
RUNTIME_STATUS_FILE = os.environ["RUN_DIR"] + "/status/runtime.status"

def max_instance_count():
    cmd = "%s max_instance_count" % (DO_SCRIPT)
    ret, output = util.run_cmd(cmd, out=True)
    if ret != 0:
        return -1
    return int(output)

def get_system_resource():
    cmd = "%s get_system_resource" % (DO_SCRIPT)
    ret, output = util.run_cmd(cmd, out=True)
    if ret != 0:
        return -1, None, None, None
    try:
        mem, disk = output.split()
        ### 100MB/s
        bandwidth = 10000
        return 0, int(mem), int(disk), bandwidth
    except:
        return -1, None, None, None

heart_beat_msg = {
    'cmd' : 'heart_beat',
    'context' : {
        'taskid' : 0,
        'capacity' : 0,
        'host' : os.environ['THIS_HOST'],
    }
}

class InstanceManagerThread(threading.Thread):
    def __init__(self, cm, im):
        threading.Thread.__init__(self)
        self.im = im
        self.running = False

    def __instances_check(self):
        def map_status(instance_name, container_id):
            status = "0"
            if container_id not in set(active_container_list):
                status = "1"
                dead_containers.append(container_id)
            elif instance_name in bad_instance_dict:
                status = bad_instance_dict[instance_name]
            else: pass
            return status
        cmd = "%s active_container_list" % (DO_SCRIPT)
        dead_containers = []
        ret, stdout = util.run_cmd(cmd, out=True)
        if ret != 0 or stdout == None:
            logging.warning("active_container_list failed: %d" % ret)
            active_container_list = []
            bad_instance_dict = {}
        else:
            active_container_list = stdout.split('\n')
            try:
                with open(RUNTIME_STATUS_FILE, "rb") as f:
                    bad_instance_dict = dict(cPickle.load(f))
            except Exception, e:
                logging.warning("read runtime.status failed: (%s)"%e)
                bad_instance_dict = {}
        suffix = "@%s" % os.environ['THIS_HOST'] 
        result = ["%s:%s"%(k.split('@')[0], map_status(k, v['container_id'])) for k,v in self.im.getall().items() if k.endswith(suffix) ]
        #### safety check, add by @yifei
        dead_count = len(dead_containers)
        if dead_count > 1:
            logging.warning("oops1: dead instance count: %d" % dead_count)
            for i in range(len(result)):
                name, status = result[i].split(':')
                if status == '1':
                    result[i] = "%s:0" % name
        return result         

    def run(self):
        self.running = True
        logging.info("thread instance-manager: running")
        self.im.load_from_disk()
        last_check = time.time()
        global heart_beat_msg
        while self.running:
            self.im.save_to_disk()
            now = time.time()
            """
            if now - last_check >= 15:
                r = self.__instances_check()
                heart_beat_msg['logid'] = '111111111111111' 
                heart_beat_msg['context']['capacity'] = 0 
                heart_beat_msg['context']['resource'] = self.im._resource
                heart_beat_msg['context']['status'] = ','.join(r)
                heart_beat_msg['context']['timestamp'] = int(now)
                try:
                    global_context.g_heartbeat_queue.put( (None, os.environ['SCHEDULER_HEARTBEAT_QUEUE'], json.dumps(heart_beat_msg)), block=False )
                except:
                    pass
                last_check = now
            """
            time.sleep(1)
        logging.info("thread instance-manager: exit")
 
    def quit(self):
        self.running = False

    def wait(self):
        self.join()

class HadesModule(object):
    def __init__(self):
        pass

    def init(self):
        #ret, mem, disk, bandwidth = get_system_resource()
        #if ret != 0:
        #    return False
        mem = 1024
        disk = 1024
        bandwidth = 100000
        self.im = InstanceManager({"mem":mem, "disk":disk, "bandwidth":bandwidth})
        self.im_thread = InstanceManagerThread(None, self.im)
        self.im_thread.start()

        import handler_manager
        _handlers = {
            "instance_create"    : self.do_instance_create,
            "instance_delete"    : self.do_instance_delete,
            "instance_list"      : self.do_instance_list,
            "instance_info"      : self.do_instance_info,
        }
        handler_manager.register_handlers(_handlers)
        return True

    def fini(self):
        self.im_thread.quit()
        self.im_thread.wait()

    def do_instance_create(self, tid, msg):
        context = msg['context']
        ### appid, app_type, instance_name, display_name, flavor, ports, environments
        reply_msg = {
            'cmd' : 'common_reply',
            'context' : {
                'taskid' : context['taskid'],
            }
        }
        instance_name = context['instance_name']
        if self.im.has(instance_name):
            reply_msg['context']['result'] = 1
            reply_msg['context']['info'] = "instance exist already"
            return 1, reply_msg

        port = context['port'] if 'port' in context else " "
        #uid = self.im.get_uid()
        if 'resource' in context:
            mem_size = context['resource']['mem'] if 'mem' in context['resource'] else ""
            disk_size = context['resource']['disk'] if 'disk' in context['resource'] else ""
            bandwidth = context['resource'].get('bandwidth', "")
        else:
            mem_size = ""
            disk_size = ""
            bandwidth = ""

        app_uri = context.get('app_uri', "")
        info = []
        info.append("arg_appid=%s\n"       % context['appid'])
        info.append("arg_imgid=%s\n"       % context['imgid'])
        info.append("arg_port='%s'\n"      % port)
        #info.append("uid=%d\n"            % uid)
        info.append("arg_mem_size='%s'\n"  % mem_size)
        info.append("arg_disk_size='%s'\n" % disk_size)
        info.append("arg_bandwidth='%s'\n" % bandwidth)
        info.append("arg_app_uri='%s'\n"   % app_uri)
        info_str = "".join(info)

        info_filename = "%s/work/%s.info" % (os.environ['RUN_DIR'], instance_name)
        with open(info_filename, "w") as fd:
            fd.write(info_str)

        cmd = "%s instance_create %s %s"  % (
            DO_SCRIPT,
            instance_name,
            info_filename)

        logging.info("thread %d: %s" % (tid, cmd))
        ret, stdout = util.run_cmd(cmd, out=True)
        os.remove(info_filename)

        if ret == 0:
            logging.info("thread %d: output(%s)" % (tid, stdout))
            aaa = stdout.split()
            logging.info(aaa)
            id, ip, public_port = stdout.split()
            instance = {
                'container_id' : id,
                'container_ip' : ip,
                'appid' : context['appid'],
                'created' : datetime.datetime.strftime(datetime.datetime.now(), "%Y%m%d-%H%M%S"),
            }
            instance['web'] = context.get("web", 0)
            self.im.add(instance_name, instance) 
            reply_msg['context']['result'] = 0
            reply_msg['context']['container_ip'] = ip
            reply_msg['context']['public_port'] = "%s" % (public_port)
        else:
            reply_msg['context']['result'] = ret
            reply_msg['context']['info'] = "app install failed"
            #self.im.put_uid(uid)
        return ret, reply_msg 

    def do_instance_delete(self, tid, msg):
        context = msg['context']
        reply_msg = {
            'cmd' : 'common_reply',
            'context' : {
                'taskid' : context['taskid'],
                'result' : 0,
            }
        }
        instance = self.im.get(context['instance_name'])
        if instance:
            self.im.delete(context['instance_name'])
            uid = instance.get('uid', -1)
            ### instance_delete [id] [ip] [ports] [uid] [port_rules]
            cmd = "%s instance_delete %s %s %s" % (DO_SCRIPT, context['instance_name'], instance['container_id'], instance['container_ip'])
            ret, _ = util.run_cmd(cmd)
            if uid != -1:
                self.im.put_uid(uid)
        return 0, reply_msg 

    def do_instance_list(self, tid, msg):
        context = msg['context']
        reply_msg = {
            'cmd' : 'common_reply',
            'context' : {
                'taskid' : context['taskid'],
                'result' : 0,
                'instances' : self.im.getall(),
            }
        }
        return 0, reply_msg 

    def do_instance_info(self, tid, msg):
        context = msg['context']
        reply_msg = {
            'cmd' : 'common_reply',
            'context' : {
                'taskid' : context['taskid'],
            }
        }
        instances = self.im.getall()
        if context['instance_name'] in instances:
            reply_msg['context']['result'] = 0
            reply_msg['context']['instances'] = instances[ context['instance_name'] ]
        else:
            reply_msg['context']['result'] = 1
            reply_msg['context']['info'] = "no such instance"
        return 0, reply_msg 

g_hades_module = HadesModule()

def init():
    return g_hades_module.init()

def fini():
    g_hades_module.fini()

