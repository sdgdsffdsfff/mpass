import os
import sys
import json
import uuid
import logging
import string
import random

from db import Database
import util

deps_dir = os.environ['AGENT_DIR'] + "/deps/lib/python2.7/site-packages/"
if sys.path[0] != deps_dir:
    sys.path.insert(0, deps_dir)

import pika

MQ_VHOST    = os.environ['SCHEDULER_VHOST']
MQ_EXCHANGE = os.environ['SCHEDULER_EXCHANGE_NAME']
MQ_SERVERS  = os.environ['RABBITMQ_SERVER_LIST']
MQ_USER     = os.environ['RABBITMQ_USER']
MQ_PASS     = os.environ['RABBITMQ_PASS']

class RPC(object):
    def __init__(self, rpc_queue=None):
        logging.getLogger('pika').setLevel(logging.CRITICAL)
        logging.getLogger('pika.channel').setLevel(logging.CRITICAL)
        self.channel = None
        self.response = None
        
        l = MQ_SERVERS.split()
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
        credentials = pika.PlainCredentials(MQ_USER, MQ_PASS)
        connection = pika.BlockingConnection(
                pika.ConnectionParameters(
                   host=server[0],
                   port=int(server[1]),
                   virtual_host=MQ_VHOST,
                   credentials=credentials) )
        channel = connection.channel()
        return channel

    def on_response(self, ch, method, props, body):
        print "response received"
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
        print "sending msg to %s:%s, reply queue %s" % (MQ_EXCHANGE, to, reply_queue)
        self.channel.basic_publish(
            exchange=MQ_EXCHANGE,
            routing_key=to,
            properties=pika.BasicProperties(reply_to = reply_queue, correlation_id = corr_id),
            body=strmsg)
        #print "wait for reply"
        self.channel.basic_consume(self.on_response, no_ack=True, queue=reply_queue)
        self.channel.start_consuming()
        #print "call finished"
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
            exchange=MQ_EXCHANGE,
            routing_key=to,
            properties=pika.BasicProperties(correlation_id = corr_id),
            body=strmsg)
        self.channel.close()
        self.channel = None
        response = self.response
        self.response = None
        return response

#node_list = ["10.154.156.122", "10.154.156.122"]
#node_list = ["10.176.28.138", "10.176.28.137", "10.176.28.139", "10.176.28.140"]
node_list = {
    "online" : ["10.176.28.138", "10.176.28.139"], 
    "sandbox" : ["10.176.28.138"]
}
router_list = ["10.154.156.122"]
#router_list = ["10.154.28.127", "10.154.28.128", "10.154.28.129", "10.154.28.130"]

g_db = Database()

def _router_update(router, context):
    rpc = RPC()
    cmd = {
        "logid" : "testlogid",
        "cmd" : "router_update", 
        "context" : {
            "taskid" : 1000,
            "domain" : context["domain"],
            "path"   : context["path"],
            "addrs"  : context["addrs"]
        } 
    }
    response = json.loads(rpc.call("router@%s"%router, json.dumps(cmd)))
    result = response["context"]["result"]
    if result != 0:
        print "route_update %s FAILED" % context["domain"] 
    else:
        print "route_update %s OK" % context["domain"]

def _router_remove(router, context):
    rpc = RPC()
    cmd = {
        "logid" : "testlogid",
        "cmd" : "router_remove", 
        "context" : {
            "taskid" : 1000,
            "domain" : context["domain"],
            "path"   : context["path"]
        } 
    }
    response = json.loads(rpc.call("router@%s"%router, json.dumps(cmd)))
    result = response["context"]["result"]
    if result != 0:
        print "route_remove %s FAILED" % context["domain"] 
    else:
        print "route_remove %s OK" % context["domain"]

def app_create(argv):
    infofile = argv[0]
    with open(infofile) as fd:
        rpc = RPC()
        cmdinfo = json.load(fd)
        appinfo, err = g_db.appCreate(
            cmdinfo["name"], 
            cmdinfo["domain"], 
            cmdinfo.get("path", ""), 
            cmdinfo["svn"], 
            cmdinfo["type"],
            cmdinfo["port"])
        if err != None:
            print "app_create Failed: %s" % err
        else:
            print "app_create OK"
        
def app_destroy(argv):
    infofile = argv[0]
    with open(infofile) as fd:
        rpc = RPC()
        cmdinfo = json.load(fd)
        name = cmdinfo["name"]
        appinfo = g_db.appGet(name)
        if appinfo == None:
            print "app_destroy Failed: no such app"
            return
    
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
            print ">>> delete old instance %s" % key
            response = json.loads(rpc.call("hades@%s"%val["node"], json.dumps(cmd)))
            result = response["context"]["result"]
            if result != 0:
                print "instance_delete %s FAILED" % key 
            else:
                print "instance_delete %s OK" % key 
            g_db.instanceDestroy(name, key)
        print ">>> remove app info from DB"
        g_db.appDestroy(cmdinfo["name"])
        context = {
            "domain" : appinfo["domain"],
            "path"   : appinfo.get("path", "")
        }
        if appinfo["type"] == "WEB":
            for router in router_list:
                print ">>> remove info from router"
                _router_remove(router, context)

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

def _node_get(group):
    return random.choice(node_list[group])

def _get_suffix():
    return ''.join(random.sample('abcdefghijklmnopqrstuvwxyz0123456789', 10))

def app_deploy(argv):
    group = argv[0]
    infofile = argv[1]
    if group not in node_list:
        print "no such group %s" % group
        return

    with open(infofile) as fd:
        rpc = RPC()
        cmdinfo = json.load(fd)
        appname = cmdinfo.get("name", None)
        appinfo = g_db.appGet(appname)
        if appinfo == None:
            print "app_destroy Failed: no such app"
            return

        print ">>> get code from svn"
        cmd = "%s/do.sh get_code %s %s" % (os.environ["AGENT_DIR"], appname, appinfo["svn"])
        ret, _ = util.run_cmd(cmd, out=False)
        if ret != 0:
            print "get code failed"
            return

        appuri = "rsync://root@10.154.156.122:/letv/run/mpass/scheduler/%s/app/" % appname
        instance_num = cmdinfo["instance_num"]

        old_instances = g_db.instanceGet(appname)
        new_instances = []

        print ">>> create new instances"
        ok = True
        for n in range(instance_num):
            node = _node_get(group)
            suffix = _get_suffix()
            instance = "instance_%s" % suffix
            port = "0"
            if appinfo["type"] == "WEB":
                port = appinfo["port"]
            cmd = {
                "logid" : "testlogid",
                "cmd" : "instance_create", 
                "context" : {
                    "taskid"        : 1000,
                    "instance_name" : instance,
                    "appid"         : appname,
                    "imgid"         : cmdinfo["imgid"],
                    "port"          : port,
                    "app_uri"       : appuri 
                } 
            }
            print "create new instance %s" % instance
            response = json.loads(rpc.call("hades@%s"%node, json.dumps(cmd)))
            result = response["context"]["result"]
            if result != 0:
                print "instance_create %s FAILED" % instance
                ok = False
                break
            new_instances.append(
                {
                    "instance" : instance,
                    "node" : node,
                    "vip"  : response["context"]["container_ip"],
                    "port" : response["context"]["public_port"],
                    "group" : group
                })

        if not ok:
            print "remove new created instances"
            for context in new_instances:
                cmd = {
                    "logid" : "testlogid",
                    "cmd" : "instance_delete", 
                    "context" : {
                        "taskid"        : 1000,
                        "instance_name" : context["instance"],
                    } 
                }
                response = json.loads(rpc.call("hades@%s"%context["node"], json.dumps(cmd)))
                result = response["context"]["result"]
                if result != 0:
                    print "instance_delete %s FAILED" % context["instance"] 
                else:
                    print "instance_delete %s OK" % context["instance"]
            return

        addrs = []
        print ">>> update info into DB"
        for context in new_instances:
            g_db.instanceCreate(appname, context)
            addrs.append("%s:%s"%(context["node"], context["port"]))

        ### update route tables
        if appinfo["type"] == "WEB":
            if len(addrs) > 0:
                context = {
                    "domain" : appinfo["domain"],
                    "path"   : appinfo.get("path", ""),
                    "addrs"  : addrs
                }
                for router in router_list:
                    print ">>> update info into router"
                    _router_update(router, context)
            else:
                context = {
                    "domain" : appinfo["domain"],
                }
                for router in router_list:
                    print ">>> update info into router"
                    _router_remove(router, context)

        print ">>> remove old instances"
        for key, val in old_instances.items():
            cmd = {
                "logid" : "testlogid",
                "cmd" : "instance_delete", 
                "context" : {
                    "taskid"        : 1000,
                    "instance_name" : key,
                } 
            }
            print ">>> delete old instance %s" % key            
            response = json.loads(rpc.call("hades@%s"%val["node"], json.dumps(cmd)))
            result = response["context"]["result"]
            if result != 0:
                print "instance_delete %s FAILED" % key 
            else:
                print "instance_delete %s OK" % key 
            g_db.instanceDestroy(appname, key)

funcs = {
    "app_create"  : app_create,
    "app_destroy" : app_destroy,
    "app_deploy"  : app_deploy,
    "app_status"  : app_status,
}

if __name__ == "__main__":
    import sys
    case = sys.argv[1]
    func = funcs.get(case, None)
    if not func:
        print "Invalid command: ", sys.argv[1]
        sys.exit(1)
    print sys.argv[2:]
    func(sys.argv[2:])

