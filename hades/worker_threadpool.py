# *-* encoding: utf-8 *-*

__author__ = 'chenyifei@baidu.com'

import logging
import threading
from threadpool import ThreadPool, WorkRequest

class WorkerThreadPool(ThreadPool):
    def __init__(self, size):
		super(WorkerThreadPool, self).__init__(size)

    def request_count(self):
        return self._requests_queue.qsize()

    def result_count(self):
        return self._results_queue.qsize()

class WorkerThread(threading.Thread):
    def __init__(self, func):
        threading.Thread.__init__(self)
        self.running = False
        self._func = func

    def run(self):
        self.running = True
        logging.info("healthy check thread is running")
        self._func(self)
        logging.info("healthy check thread is quit")
    
    def quit(self):
        self.running = False

    def wait(self):
        self.join()

