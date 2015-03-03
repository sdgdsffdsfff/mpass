import os
import pika
import json
import logging
import threading
import signal
import traceback
import time

import Queue
from threadpool import WorkRequest, NoResultsPending
from worker_threadpool import WorkerThreadPool

import handler_manager
import global_context

logging.getLogger('pika').setLevel(logging.CRITICAL)
logging.getLogger('pika.channel').setLevel(logging.CRITICAL)

def task_done(request, result):
    #logging.info("task done")
    pass

def do_no_handler(tid, msg):
    logging.warning("thread %d: unsupport command (%s)" % (tid, msg['cmd']))
    reply_msg = { 'cmd':'common_reply', 'logid':msg['logid'], 'context':{'result':1001, "info":"unsupport message"}}
    return 1, None

def set_options(msg):
    if 'debug_mode' in msg['context']:
        global_context.g_debug_mode = msg['context']['debug_mode']
        logging.debug("change debug mode to %s" % global_context.g_debug_mode)

def worker_thread_callback(tid, task):
    msg = task['msg']
    logging.info("thread %d: (%s) (%s) task_begin" %(tid, msg['logid'], msg['cmd']))
    begin_time = time.time()*1000
    handler = handler_manager.get(msg['cmd'])
    if not handler:
        handler = do_no_handler

    try:    
        result, reply_msg = handler(tid, msg)
    except Exception, e:
        logging.warning("thread %d: logid %s %s" %(tid, msg['logid'], "WARNING: exception in handler"))
        logging.warning(traceback.format_exc())
        reply_msg = { 
            'cmd':'common_reply', 
            'logid' : msg['logid'], 
            'context': {
                'taskid' : msg['context']['taskid'],
                'result' : 1000, 
                "info"   : "exception happend",
            }
        }
        result = 1

    logging.info("thread %d: (%s) (%s) task_end %s %d %dms" %(
                tid, msg['logid'], msg['cmd'],
                "success" if result == 0 else "failed",  
                result,  
                time.time()*1000-begin_time))

    if reply_msg and task['reply_queue']:
        reply_msg['logid'] = msg['logid']
        try:
            global_context.g_reply_queue.put( (task, task['reply_queue'], json.dumps(reply_msg)), block=False)
        except Queue.Full:
            logging.warning("oops0: reply queue is full")
    return result

class TaskManager(object):
    def __init__(self):
        self._waiting = {}

    ### add a task 
    def add(self, task, k):
        if k in self._waiting:
            self._waiting[k].append(task)
        else:
            self._waiting[k] = [task]
        logging.info("thread main: add task (%s) (%s), (%d)" % (k, task['msg']['cmd'], len(self._waiting[k])))

    ### remove a finished task, and return next msg
    def remove(self, task, k):
        l = self._waiting[k]
        logging.info("thread main: remove task(%s) (%s), (%d)" % (k, task['msg']['cmd'], len(l)))
        self._waiting[k] = l[1:]
        if len(self._waiting[k]) == 0:
            del self._waiting[k]
            return None
        return self._waiting[k][0]

    def busy(self, k):
        return k in self._waiting

class Consumer(threading.Thread):
    def __init__(self, servers, vhost, user, passwd, exchange, routing_key, worker_num):
        self._connection = None
        self._channel = None

        self._reply_connection = None
        self._reply_channel = None
        self._closing = False
        self.running = False
       
        self.vhost = vhost
        self.user = user
        self.passwd = passwd
        self.exchange = exchange
        self.routing_key = routing_key
        self.worker_num = worker_num

        l = servers.split()
        self.mq_servers = [x.split(':') for x in l]
        self.mq_count = len(self.mq_servers)
        self.mq_index = 0

        self.task_manager = TaskManager()
        self.worker_pool = WorkerThreadPool(worker_num)
        threading.Thread.__init__(self)
 
    def _get_server(self):
        x = self.mq_servers[self.mq_index]
        self.mq_index += 1
        if self.mq_index >= self.mq_count:
            self.mq_index = 0
        return x

    def connect(self):
        try:
            credentials = pika.PlainCredentials(self.user, self.passwd)
            server = self._get_server()
            logging.info('Connecting to %s:%s' % (server[0], server[1]))
            return pika.BlockingConnection( 
                    pika.ConnectionParameters(
                        host=server[0],
                        port=int(server[1]),
                        virtual_host=self.vhost,
                        #heartbeat_interval=3,
                        credentials=credentials) )
        except:
             logging.warning("exception: connection")
             logging.warning(traceback.format_exc())
             return None
 
    def on_message(self, unused_channel, basic_deliver, properties, body):
        logging.info('Received message # %s: %s', basic_deliver.delivery_tag, body)
        try:
            msg = json.loads(body)
            if 'logid' not in msg or 'cmd' not in msg or 'context' not in msg:
                logging.warning("thread main: invalid msg (%s)" % body)
                self._channel.basic_ack(basic_deliver.delivery_tag)
                return
        except:
            logging.warning("thread main: invalid msg (%s)" % body)
            self._channel.basic_ack(basic_deliver.delivery_tag)
            return

        if msg['cmd'] == "set_options":
            set_options(msg)
            return

        task = { 
            'msg' : msg, 
            'reply_queue' : properties.reply_to, 
            'delivery_tag' : basic_deliver.delivery_tag 
        } 

        key = msg['context']['instance_name'] if 'instance_name' in msg['context'] else None
        if not key:
            self.worker_pool.putRequest( WorkRequest(worker_thread_callback, [task], callback=task_done) )
        else:
            if self.task_manager.busy(key):
                self.task_manager.add(task, key)
            else:
                self.task_manager.add(task, key)
                self.worker_pool.putRequest( WorkRequest(worker_thread_callback, [task], callback=task_done) )
 
    def run(self):
        self.running = True
        logging.info("consumer thread running")
        while self.running:
            try:
                ### make connection
                self._connection = self.connect()
                if not self._connection:
                    time.sleep(1)
                    continue
                logging.info("connected")
                ### make channel
                self._channel = self._connection.channel()

                ### declare queue
                result = self._channel.queue_declare(exclusive=True)
                self.queue_name = result.method.queue
                logging.info("queue: %s" % self.queue_name)

                ### bind queue
                self._channel.queue_bind(exchange=self.exchange, queue=self.queue_name, routing_key=self.routing_key)

                ### send basic consume
                self._channel.basic_qos(prefetch_count=self.worker_num)
                self._channel.basic_consume(self.on_message, self.queue_name)

                ### consumer thread main loop
                try:
                    last_check = time.time()
                    while len(self._channel._consumers): 
                        self._connection.process_data_events()
                        self._handle_reply_queue()
                        self._handle_heartbeat_queue()
                        now = time.time()
                        if now-last_check > 60:
                            status_list = self.worker_pool.getWorkersStatus()
                            last_check = now
                            overtime_cnt = 0
                            for busy, start in status_list:
                                if busy and (now-start > 600):
                                    overtime_cnt += 1
                            if overtime_cnt > 0:
                                logging.warning("oops1: %d threads worked overtime" % overtime_cnt)
                        time.sleep(0.2)
                except:
                    logging.warning(traceback.format_exc())
                    try:
                        self._connection.close()
                    except:
                        pass
                    self._channel = None
                    self._connection = None
            except:
                logging.warning(traceback.format_exc())
                try:
                    if self._connection:
                        self._connection.close()
                except:
                    pass
                self._channel = None
                self._connection = None
                continue
        logging.info("consumer thread exited")

    def stop(self):
        logging.info('Stopping consumer')
        self._closing = True
        self.running = False
        self.worker_pool.dismissWorkers(self.worker_num)
        self.worker_pool.joinAllDismissedWorkers()
        if self._channel:
            self._channel.stop_consuming()
        logging.info('Stopped')
 
    def wait(self):
        self.join()

    def ack(self, tag):
        try:
            if self._channel:
                self._channel.basic_ack(tag)
                #logging.info("ack success (%d)" % tag)
            return True
        except:
            return False

    def _reply(self, reply_queue, strmsg, retry):
        ret = True
        if not self._connection:
           self._connection = self.connect()
           if not self._connection:
               logging.warning("reply: failed to connect")
               return False

        if not self._channel:
           try:
               self._channel = self._connection.channel()
           except:
               logging.warning("make reply channel failed")
               return False

        try:
            self._channel.basic_publish(exchange='', routing_key=reply_queue, body=strmsg)
        except Exception, e:
            logging.warning(traceback.format_exc())
            logging.warning("send msg to %s failed %d" % (reply_queue, len(strmsg)))
            try:
                self._connection.close()
            except:
                pass
            self._channel = None
            self._connection = None
            ret = False
        return ret
    
    def reply(self, reply_queue, strmsg, retry_cnt=1):
        retry = 0
        while retry < retry_cnt:
            if not self._reply(reply_queue, strmsg, retry):
                retry = retry+1
                continue
            return True
        return False
    
    def _handle_reply_queue(self):
        try:
            self.worker_pool.poll()
        except KeyboardInterrupt:
            pass
        except NoResultsPending:
            pass

        ## handle result queue
        try:
            task, qname, reply_msg = global_context.g_reply_queue.get(block=False)
            #logging.info("get reply msg to (%s)" % qname)
            retry_cnt = 3
            key = task['msg']['context']['instance_name'] if 'instance_name' in task['msg']['context'] else None
            if key:
                next_task = self.task_manager.remove(task, key)
                if next_task:
                    self.worker_pool.putRequest( WorkRequest(worker_thread_callback, [next_task], callback=task_done) )

            self.ack(task['delivery_tag'])
            self.reply(qname, reply_msg, retry_cnt)
        except Queue.Empty, e:
            pass
        except Exception, e:
            logging.warning(traceback.format_exc())
            pass

    def _handle_heartbeat_queue(self):
        try:
            _, qname, reply_msg = global_context.g_heartbeat_queue.get(block=False)
            retry_cnt = 1
            self.reply(qname, reply_msg, retry_cnt)
            ###
            #logging.info("heartbeat send to %s with %s"%(qname, reply_msg[:32]))
            ###
        except Queue.Empty, e:
            pass
        except Exception, e:
            logging.warning(traceback.format_exc())
            pass

