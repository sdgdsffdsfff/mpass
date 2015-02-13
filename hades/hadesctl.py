import os
import sys
import json
import uuid
import logging

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

def instance_create(argv):
    cmdfile = argv[0]
    with open(cmdfile) as fd:
        msg = json.load(fd)
        rpc = RPC()
        reply_msg = json.loads(rpc.call(THIS_AGENT_NAME, json.dumps(msg)))

def instance_delete(argv):
    instance_name = argv[0]
    rpc = RPC()
    msg = { 
        'logid' : 'testlogid',
        "cmd" : "instance_delete", 
        "context" : {
            'taskid' : 1000,
            'instance_name' : instance_name,
         } 
    }
    reply_msg = json.loads(rpc.call(THIS_AGENT_NAME, json.dumps(msg)))

def instance_list(argv):
    rpc = RPC()
    msg = { 
        'logid' : 'testlogid',
        "cmd" : "instance_list", 
        "context" : {
            'taskid' : 1000,
         } 
    }
    reply_msg = json.loads(rpc.call(THIS_AGENT_NAME, json.dumps(msg)))
    instances = reply_msg['context']['instances']
    for k, v in instances.items():
        print "==============================================================="
        try:
            print "instance_name: ", k
            print "container_id:  ", v['container_id']
            print "container_ip:  ", v['container_ip']
            print "appid:         ", v['appid'] if 'appid' in v else "NONE"
            print "app_type:      ", v['app_type'] if 'app_type' in v else "NONE"
            print "created:       ", v['created'] if 'created' in v else "NONE"
            print "uid:           ", v['uid'] if 'uid' in v else "NONE"
            print "longid:        ", v['longid'] if 'longid' in v else "NONE"
        except:
            pass
    print len(instances)

def instance_info(argv):
    rpc = RPC()
    msg = { 
        'logid' : 'testlogid',
        "cmd" : "instance_info", 
        "context" : {
            'taskid' : 1000,
            'instance_name' : argv[0]
         } 
    }
    reply_msg = json.loads(rpc.call(THIS_AGENT_NAME, json.dumps(msg)))
    print reply_msg

def instance_create_async(argv):
    instance_name = argv[0]
    display_name = argv[1]
    appid = argv[2]
    app_type = argv[3]
    flavor = int(argv[4])
    environments = argv[5]
    port_maps = argv[6]
    rpc = RPC()
    msg = { 
        'logid' : 'testlogid',
        "cmd" : "instance_create", 
        "context" : {
            'taskid' : 1000,
            'instance_name' : instance_name,
            'display_name'  : display_name,
            'appid' : appid,
            'app_type' : app_type,
            'flavor' : flavor,
            "environments" : environments,
            "port_maps" : port_maps,
         } 
    }
    rpc.cast(THIS_AGENT_NAME, json.dumps(msg))

def instance_delete_async(argv):
    instance_name = argv[0]
    rpc = RPC()
    msg = { 
        'logid' : 'testlogid',
        "cmd" : "instance_delete", 
        "context" : {
            'taskid' : 1000,
            'instance_name' : instance_name,
         } 
    }
    rpc.cast(THIS_AGENT_NAME, json.dumps(msg))

def set_debug_mode(argv):
    debug_mode = False if argv[0] == "0" else True
    rpc = RPC()
    msg = { 
        'logid' : 'testlogid',
        "cmd" : "set_options", 
        "context" : {
            'taskid' : 1000,
            'debug_mode' : debug_mode,
         } 
    }
    rpc.cast(THIS_AGENT_NAME, json.dumps(msg))

def instance_create_custom(argv):
    instance_name = argv[0]
    appid = argv[1]
    app_location = argv[2]

    rpc = RPC()
    msg = { 
        'logid' : 'testlogid',
        "cmd" : "instance_create", 
        "context" : {
            'taskid'        : 1000,
            'instance_name' : instance_name,
            'display_name'  : instance_name,
            'appid'         : appid,
            'app_type'      : "custom",
            'flavor'        : 10,
            "environments"  : "",
            "port_maps"     : "",
            "app_location" : app_location,
         } 
    }

    reply_msg = json.loads(rpc.call(THIS_AGENT_NAME, json.dumps(msg)))

funcs = {
    "instance_create" : instance_create,
    "instance_create_custom" : instance_create_custom,
    "instance_delete" : instance_delete,
    "instance_list" : instance_list,
    "instance_info" : instance_info,

    "instance_create_async" : instance_create_async,
    "instance_delete_async" : instance_delete_async,
    "set_debug_mode" : set_debug_mode,
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

