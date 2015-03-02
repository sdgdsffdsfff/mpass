import os
import logging
import threading
import time
import cPickle
import json

STATUS_FILE = "%s/status/instance.status" % os.environ['RUN_DIR']
JSON_FILE = "%s/status/instance.json" % os.environ['RUN_DIR']

class InstanceManager():
    def __init__(self, resource):
        self._lock = threading.Lock()
        self._instances = {}
        self._uid_pool = range(21999, 19999, -1)
        self._resource = resource
        self._changed = False

    def load_from_disk(self):
        self._lock.acquire()
        try:
            with open(STATUS_FILE, "rb") as fd:
                a = cPickle.load(fd)
                self._instances = a
            for k,v in self._instances.items():
                if 'uid' in v and v['uid'] in self._uid_pool:
                    self._uid_pool.remove(v['uid'])
        except:
            pass
        self._changed = True
        self._lock.release()

    def save_to_disk(self):
        self._lock.acquire()
        if self._changed:
            try:
                with open(STATUS_FILE, "wb") as fd:
                    cPickle.dump(self._instances, fd, cPickle.HIGHEST_PROTOCOL)
                with open(JSON_FILE, "wb") as fd:
                    json.dump(self._instances, fd)
                self._changed = False
            except:
                pass
        self._lock.release()

    def has(self, instance_name):
        self._lock.acquire()
        r = True if instance_name in self._instances else False
        self._lock.release()
        return r 
 
    def get(self, instance_name):
        instance = None
        self._lock.acquire()
        if instance_name in self._instances:
            instance = self._instances[instance_name]
        self._lock.release()
        return instance

    def add(self, instance_name, instance):
        self._lock.acquire()
        if instance_name in self._instances:
            self._lock.release()
            return None 
        self._instances[instance_name] = instance
        self._changed = True
        self._lock.release()
        return instance 

    def delete(self, instance_name):
        self._lock.acquire()
        if instance_name in self._instances:
            del self._instances[instance_name]
            self._changed = True
        self._lock.release()

    """
    def full(self):
        self._lock.acquire()
        full = True if len(self._instances) >= self._max else False
        self._lock.release()
        return full
    """

    def getall(self):
        return self._instances 

    def get_uid(self):
        self._lock.acquire()
        uid = self._uid_pool.pop()
        self._lock.release()
        return uid

    def put_uid(self, uid):
        self._lock.acquire()
        if uid not in self._uid_pool:
            self._uid_pool.append(uid)
        self._lock.release()


