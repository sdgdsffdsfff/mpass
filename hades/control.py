import os
import sys
import json
import uuid
import logging
import string
import random

deps_dir = os.environ['AGENT_DIR'] + "/deps/lib/python2.7/site-packages/"
if sys.path[0] != deps_dir:
    sys.path.insert(0, deps_dir)
import pika

SCHEDULER_VHOST         = os.environ['SCHEDULER_VHOST']
SCHEDULER_EXCHANGE_NAME = os.environ['SCHEDULER_EXCHANGE_NAME']
THIS_AGENT_NAME    = os.environ['THIS_AGENT_NAME']

class RPC(object):
    def __init__(self, rpc_queue=None):
        logging.getLogger('pika').setLevel(logging.CRITICAL)
        logging.getLogger('pika.channel').setLevel(logging.CRITICAL)
        self.channel = None
        self.response = None
        
        l = os.environ['RABBITMQ_SERVER_LIST'].split()
        self.mq_servers = [x.split(':') for x in l]
        self.mq_count = len(self.mq_servers)
        self.mq_index = 0

    def _get_server(self):
        x = self.mq_servers[self.mq_index]
        self.mq_index += 1
        if self.mq_index >= self.mq_count:
            self.mq_index = 0
        return x

    def _make_channel(self):
        server = self._get_server()
        credentials = pika.PlainCredentials(os.environ['RABBITMQ_USER'], os.environ['RABBITMQ_PASS'])
        connection = pika.BlockingConnection(
                pika.ConnectionParameters(
                   host=server[0],
                   port=int(server[1]),
                   virtual_host=SCHEDULER_VHOST,
                   credentials=credentials) )
        channel = connection.channel()
        #channel.exchange_declare(exchange=SCHEDULER_EXCHANGE_NAME, type='direct', auto_delete=False)
        return channel

    def on_response(self, ch, method, props, body):
        print "recv response"
        #print body
        self.response = body
        self.channel.stop_consuming()

    def call(self, to, strmsg):
        self.response = None
        corr_id = str(uuid.uuid4())
        self.channel = self._make_channel()
        ### reply queue, created by producer...
        result = self.channel.queue_declare(exclusive=True, auto_delete=True)
        reply_queue = result.method.queue
        print "sending msg to %s:%s, reply queue %s" % (SCHEDULER_EXCHANGE_NAME, to, reply_queue)
        self.channel.basic_publish(
            exchange=SCHEDULER_EXCHANGE_NAME,
            routing_key=to,
            properties=pika.BasicProperties(reply_to = reply_queue, correlation_id = corr_id),
            body=strmsg)
        print "wait for reply"
        self.channel.basic_consume(self.on_response, no_ack=True, queue=reply_queue)
        self.channel.start_consuming()
        print "call finished"
        self.channel.close()
        self.channel = None
        response = self.response
        self.response = None
        return response

    def cast(self, to, strmsg):
        self.response = None
        corr_id = str(uuid.uuid4())
        self.channel = self._make_channel()
        self.channel.basic_publish(
            exchange=SCHEDULER_EXCHANGE_NAME,
            routing_key=to,
            properties=pika.BasicProperties(correlation_id = corr_id),
            body=strmsg)
        self.channel.close()
        self.channel = None
        response = self.response
        self.response = None
        return response

node_list = ["10.154.156.122", "10.154.156.122"]

class Database(object):
    def __init__(self):
        self._load()

    def _load(self):
        try:
            with open("db.json") as fd:
                 self.db = json.load(fd)
        except:
            self.db = {
                 "apps" : {},
                 "instances" : {}
            }

    def _sync(self):
        with open("db.json", "w") as fd:
            json.dump(self.db, fd)

    def appCreate(self, name, domain, svn, port):
        apps = self.db["apps"]
        if name in apps:
            return None, "exits"
        apps[name] = {
            "domain" : domain,
            "svn" : svn,
            "port" : port,
            "status" : 0
        }
        instances = self.db["instances"]
        instances[name] = {}
        self._sync()
        return apps[name], None

    def appDestroy(self, name):
        apps = self.db["apps"]
        if name not in apps:
            return "no such app"
        instances = self.db["instances"]
        if len(instances[name]) != 0:
            return "has instances"
        apps.pop(name)
        instances.pop(name)
        self._sync()
        return None
        
    def appGet(self, name):
        apps = self.db["apps"]
        return apps.get(name, None)

    def nodeGet(self):
        return "10.154.156.122"

    def instanceCreate(self, name, instance, nodeip, vip, port):
        instances = self.db["instances"]
        instances[name][instance] = { 
            "status" : "running",
            "nodeip" : nodeip,
            "vip" : vip,
            "port" : port
        }
        self._sync()
        return True

    def instanceDestroy(self, name, instance):
        instances = self.db["instances"]
        instances[name].pop(instance)
        self._sync()

    def instanceGet(self, name):
        instances = self.db["instances"]
        return instances.get(name, {})

g_db = Database()
    
def app_create(argv):
    infofile = argv[0]
    with open(infofile) as fd:
        rpc = RPC()
        cmdinfo = json.load(fd)
        appinfo, err = g_db.appCreate(
            cmdinfo["name"], 
            cmdinfo["domain"], 
            cmdinfo["svn"], 
            cmdinfo["port"])
        if err != None:
            print "FAILED: %s" % err
        else:
            print "OK"
        
def app_destroy(argv):
    infofile = argv[0]
    with open(infofile) as fd:
        rpc = RPC()
        cmdinfo = json.load(fd)
        appinfo = g_db.appGet(cmdinfo["name"])
        if appinfo == None:
            print "no such app"
            return
        #instance_info = db.instanceGet(cmdinfo["name"])
        #for instance in instance_info:
        g_db.appDestroy(cmdinfo["name"])
            
def app_restart(argv):
    pass

def app_status(argv):
    infofile = argv[0]
    with open(infofile) as fd:
        rpc = RPC()
        cmdinfo = json.load(fd)
        appinfo = g_db.appGet(cmdinfo["name"])
        if appinfo == None:
            print "no such app"
            return
        instance_info = g_db.instanceGet(cmdinfo["name"])
        print "===================================="
        print "APP has %d instance" % len(instance_info)
        for key, val in instance_info.items():
            print key
            print val
        print "===================================="

def app_deploy(argv):
    infofile = argv[0]
    with open(infofile) as fd:
        rpc = RPC()
        cmdinfo = json.load(fd)
        name = cmdinfo.get("name", None)
        appinfo = g_db.appGet(name)
        if appinfo == None:
            print "no such app"
            return

        instance_num = cmdinfo["instance_num"]
        
        tmp = []
        for n in range(instance_num):
            node = g_db.nodeGet()
            suffix = ''.join(random.sample('abcdefghijklmnopqrstuvwxyz0123456789', 10))
            instance = "instance_%s" % suffix
            cmd = {
                "logid" : "testlogid",
                "cmd" : "instance_create", 
                "context" : {
                    "taskid"        : 1000,
                    "instance_name" : instance,
                    "appid"         : name,
                    "imgid"         : cmdinfo["imgid"],
                    "port"          : appinfo["port"],
                    "app_uri"       : "file:///letv/hades/testapp1"
                } 
            }
            response = json.loads(rpc.call("hades@%s"%node, json.dumps(cmd)))
            result = response["context"]["result"]
            if result != 0:
                print "instance_create %s FAILED" % instance
                return
            print "instance_create %s OK" % instance
            tmp.append((instance, response))

        old_instances = g_db.instanceGet(name)
        for key, val in old_instances.items():
            cmd = {
                "logid" : "testlogid",
                "cmd" : "instance_delete", 
                "context" : {
                    "taskid"        : 1000,
                    "instance_name" : key,
                } 
            }
            response = json.loads(rpc.call("hades@%s"%val["nodeip"], json.dumps(cmd)))
            result = response["context"]["result"]
            if result != 0:
                print "instance_delete %s FAILED" % key 
            else:
                print "instance_delete %s OK" % key 
            g_db.instanceDestroy(name, key)

        for instance, response in tmp:
            g_db.instanceCreate(name, instance, node, response["context"]["container_ip"], response["context"]["public_port"])

funcs = {
    "app_create"  : app_create,
    "app_destroy"  : app_destroy,
    "app_deploy"  : app_deploy,
    "app_restart" : app_restart,
    "app_status"  : app_status,
}

if __name__ == "__main__":
    import sys
    case = sys.argv[1]
    func = funcs.get(case, None)
    if not func:
        print "Invalid testcase: ", sys.argv[1]
        sys.exit(1)

    print sys.argv[2:]
    func(sys.argv[2:])

